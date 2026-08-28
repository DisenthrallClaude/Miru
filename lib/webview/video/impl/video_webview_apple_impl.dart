import 'dart:async';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/webview/video/video_webview_controller.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:miru/utils/http_headers.dart';
import 'package:miru/utils/media.dart';
import 'package:miru/webview/video/sniffed_url_filter.dart';

class VideoWebviewAppleImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;

  /// 当前已注入嗅探脚本的解析器模式（null = 尚未注入）。
  /// 「超时换解析器重试」以翻转的模式再次 loadUrl 时换注对应 UserScript。
  bool? _injectedParserLegacy;

  @override
  Future<void> init() async {
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        // 嗅探脚本改为在 loadUrl 时统一注入（见 [addUserScripts]）：
        // 换解析器重试需要 removeAllUserScripts 后重注，若依赖
        // initialUserScripts，重注后懒加载移除脚本会丢失。
        initialSettings: InAppWebViewSettings(
          // 与 mpv 播放共用会话 UA：解析与播放必须同源，否则防盗链 CDN 拒播
          userAgent: getSessionUA(),
          mediaPlaybackRequiresUserGesture: true,
          useOnLoadResource: false,
          cacheEnabled: false,
          isInspectable: false,
          contentBlockers: [
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?devtools-detector\.js",
                  resourceType: [
                    ContentBlockerTriggerResourceType.SCRIPT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(urlFilter: '.*', resourceType: [
                ContentBlockerTriggerResourceType.IMAGE,
              ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?googleads",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?googlesyndication\.com",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?prestrain\.html",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?prestrain%2Ehtml",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?adtrafficquality",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
          ],
        ),
        onWebViewCreated: (controller) {
          MiruLogger().i('WebView: created');
          webviewController = controller;
          initEventController.add(true);
        },
        onLoadStart: (controller, url) {
          logEventController.add('started loading: $url');
        },
        onLoadStop: (controller, url) {
          logEventController.add('loading completed: $url');
        },
        onReceivedError: (controller, request, error) {
          MiruLogger().e(
              'WebView: error: ${error.toString()} - Request: ${request.url}');
        },
      ),
    );
    await headlessWebView?.run();
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    if (_injectedParserLegacy != useLegacyParser) {
      addJavaScriptHandlers();
      await _replaceUserScripts(useLegacyParser);
      _injectedParserLegacy = useLegacyParser;
    }
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;

    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _replaceUserScripts(bool useLegacyParser) async {
    await webviewController?.removeAllUserScripts();
    await addUserScripts(useLegacyParser);
  }

  /// 两套桥 handler 常驻注册：注入脚本按解析器模式只调用其中一套，
  /// 避免换解析器重试时脚本调用未注册的 handler。
  void addJavaScriptHandlers() {
    logEventController.add('Adding LogBridge handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'LogBridge',
        callback: (args) {
          String message = args[0].toString();
          if (message.contains('about:blank')) {
            return;
          }
          logEventController.add(message);
        });

    logEventController.add('Adding JSBridgeDebug handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'JSBridgeDebug',
        callback: (args) {
          String message = args[0].toString();
          logEventController.add('Callback received: $message');
          logEventController.add(
              'If there is audio but no video, please report it to the rule developer.');
          if ((message.contains('http') || message.startsWith('//')) &&
              !SniffedUrlFilter.isAdUrl(message)) {
            logEventController.add('Parsing video source $message');
            String encodedUrl = Uri.encodeFull(message);
            if (decodeVideoSource(encodedUrl) != encodedUrl) {
              isIframeLoaded = true;
              isVideoSourceLoaded = true;
              logEventController.add(
                  'Loading video source ${decodeVideoSource(encodedUrl)}');
              unloadPage();
              final videoUrl = decodeVideoSource(encodedUrl);
              notifyVideoSourceResolved(videoUrl);
            }
          }
        });

    logEventController.add('Adding VideoBridgeDebug handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'VideoBridgeDebug',
        callback: (args) {
          String message = args[0].toString();
          logEventController.add('Callback received: $message');
          // 协议相对地址（//cdn.com/x.m3u8）不含 "http" 子串，
          // 不补全会被下面的 http 检查直接拒收。
          if (message.startsWith('//')) {
            message = 'https:$message';
          }
          if (message.contains('http') &&
              !isVideoSourceLoaded &&
              !SniffedUrlFilter.isAdUrl(message)) {
            logEventController.add('Loading video source: $message');
            isIframeLoaded = true;
            isVideoSourceLoaded = true;
            unloadPage();
            notifyVideoSourceResolved(message);
          }
        });
  }

  /// iframe 懒加载移除脚本（原先在 initialUserScripts 里，改为随
  /// addUserScripts 统一注入，避免换解析器重注时丢失）。
  static const String _lazyLoadingScript = '''
    function removeLazyLoading() {
      document.querySelectorAll('iframe[loading="lazy"]').forEach(iframe => {
        console.log('Removing lazy loading from:', iframe.src);
        iframe.removeAttribute('loading');
      });
    }
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', removeLazyLoading);
    } else {
      removeLazyLoading();
    }
  ''';

  Future<void> addUserScripts(bool useLegacyParser) async {
    final List<UserScript> scripts = [
      UserScript(
        source: _lazyLoadingScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        forMainFrameOnly: false,
      ),
    ];

    if (useLegacyParser) {
      logEventController.add('Adding JSBridgeDebug UserScript');
      const String jsBridgeDebugScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
        var iframes = document.getElementsByTagName('iframe');
        window.flutter_inappwebview.callHandler('LogBridge', 'The number of iframe tags is ' + iframes.length);
        for (var i = 0; i < iframes.length; i++) {
            var iframe = iframes[i];
            var src = iframe.getAttribute('src');
            if (src) {
              window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
            }
        }
      """;
      scripts.add(UserScript(
        source: jsBridgeDebugScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        forMainFrameOnly: false,
      ));
    } else {
      logEventController.add('Adding VideoBridgeDebug UserScripts');
      const String blobParserScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'BlobParser script loaded: ' + window.location.href);
        const _r_text = window.Response.prototype.text;
        window.Response.prototype.text = function () {
            return new Promise((resolve, reject) => {
                _r_text.call(this).then((text) => {
                    resolve(text);
                    if (text.trim().startsWith("#EXTM3U")) {
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + this.url);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                    }
                }).catch(reject);
            });
        }

        const _open = window.XMLHttpRequest.prototype.open;
        window.XMLHttpRequest.prototype.open = function (...args) {
            this.addEventListener("load", () => {
                try {
                    let content = this.responseText;
                    if (content.trim().startsWith("#EXTM3U")) {
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + args[1]);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1]);
                    };
                } catch {}
            });
            return _open.apply(this, args);
        };
      """;

      const String videoTagParserScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);
        function processVideoElement(video) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
          let src = video.getAttribute('src');
          if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
            window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
            return;
          }
          const sources = video.getElementsByTagName('source');
          for (let source of sources) {
            src = source.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
              return;
            }
          }
        }

        document.querySelectorAll('video').forEach(processVideoElement);

        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for video elements...');
          mutations.forEach(mutation => {
            if (mutation.type === 'attributes' && mutation.target.nodeName === 'VIDEO') {
              processVideoElement(mutation.target);
            }
            mutation.addedNodes.forEach(node => {
              if (node.nodeName === 'VIDEO') processVideoElement(node);
              if (node.querySelectorAll) {
                node.querySelectorAll('video').forEach(processVideoElement);
              }
            });
          });  
        });

        _observer.observe(document.body, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src']
        });
    """;
      scripts.add(UserScript(
        source: blobParserScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
      scripts.add(UserScript(
        source: videoTagParserScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        forMainFrameOnly: false,
      ));
    }

    await webviewController?.addUserScripts(
      userScripts: scripts,
    );
  }

  @override
  Future<void> unloadPage() async {
    // init 未完成时不硬崩（对齐 Android 实现）。
    await webviewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri("about:blank")));
  }

  @override
  Future<void> dispose() async {
    await headlessWebView?.dispose();
    headlessWebView = null;
    webviewController = null;
    disposeEventControllers();
  }
}
