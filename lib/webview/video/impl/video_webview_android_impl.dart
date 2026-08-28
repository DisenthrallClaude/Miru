import 'dart:async';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/network/proxy_utils.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/webview/video/video_webview_controller.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    as android_webview;
import 'package:miru/utils/media.dart';
import 'package:miru/utils/http_headers.dart';
import 'package:miru/webview/video/sniffed_url_filter.dart';

class VideoWebviewAndroidImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;

  /// 当前已注入嗅探脚本的解析器模式（null = 尚未注入）。
  /// 「超时换解析器重试」会以翻转的模式再次 loadUrl，若沿用首次注入
  /// 的那套 UserScript，重试只是原脚本下多等一轮超时（伪重试）。
  bool? _injectedParserLegacy;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialSettings: InAppWebViewSettings(
          // 与 mpv 播放共用会话 UA：解析与播放必须同源，否则防盗链 CDN 拒播
          userAgent: getSessionUA(),
          mediaPlaybackRequiresUserGesture: true,
          cacheEnabled: false,
          blockNetworkImage: true,
          loadsImagesAutomatically: false,
          upgradeKnownHostsToHTTPS: false,
          safeBrowsingEnabled: false,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
          geolocationEnabled: false,
        ),
        onWebViewCreated: (controller) {
          MiruLogger().i('[WebView] Created');
          webviewController = controller;
          initEventController.add(true);
        },
        onLoadStart: (controller, url) async {
          logEventController.add('started loading: $url');
        },
        onLoadStop: (controller, url) {
          logEventController.add('loading completed: $url');
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
  /// 常驻可避免「换解析器重试后脚本调用了未注册的 handler」而必然超时。
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
            // 嗅探到的 .m3u8 显式标注 HLS：mpv 侧据此强制
            // demuxer-lavf-format=hls，避开内容探测失误
            // （对齐上游 Windows 平台 43e0fe8 的做法）。
            notifyVideoSourceResolved(
              message,
              format: _isHlsUrl(message)
                  ? VideoSourceFormat.hls
                  : VideoSourceFormat.auto,
            );
          }
        });
  }

  Future<void> addUserScripts(bool useLegacyParser) async {
    final List<UserScript> scripts = [];

    if (useLegacyParser) {
      logEventController.add('Adding JSBridgeDebug UserScript');
      const String jsBridgeDebugScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
        function processIframeElement(iframe) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Processing iframe element');
          let src = iframe.getAttribute('src');
          if (src) {
            window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
          }
        }

        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for iframes...');
          mutations.forEach(mutation => {
            if (mutation.type === 'attributes' && mutation.target.nodeName === 'IFRAME') {
              processIframeElement(mutation.target);
            } else {
              mutation.addedNodes.forEach(node => {
                if (node.nodeName === 'IFRAME') processIframeElement(node);
                if (node.querySelectorAll) {
                  node.querySelectorAll('iframe').forEach(processIframeElement);
                }
              });
            }
          });  
        });

        _observer.observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src']
        });
      """;
      scripts.add(UserScript(
        source: jsBridgeDebugScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        // 跨域 iframe 播放器也必须被注入：显式钉死 false，
        // 不依赖包版本的平台默认值。
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
                        // 站点可能给相对地址；统一在 JS 侧按页面 baseURI 补全，
                        // 否则 mpv 收到相对路径必然 Failed to open。
                        let requestUrl = args[1];
                        try { requestUrl = new URL(requestUrl, document.baseURI).href; } catch {}
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + requestUrl);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', requestUrl);
                    };
                } catch {}
            });
            return _open.apply(this, args);
        };
      """;

      const String videoTagParserScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);
        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for video elements...');
          for (const mutation of mutations) {
            if (mutation.type === "attributes" && mutation.target.nodeName === "VIDEO") {
              if (processVideoElement(mutation.target)) return;
              continue;
            }
            for (const node of mutation.addedNodes) {
              if (node.nodeName === "VIDEO") {
                if (processVideoElement(node)) return;
              }
              if (node.querySelectorAll) {
                for (const video of node.querySelectorAll("video")) {
                  if (processVideoElement(video)) return;
                }
              }
            }
          }
        });
        function toAbsoluteUrl(raw) {
          // 相对路径按页面 baseURI 补全；失败时返回原值由 Dart 侧过滤。
          try { return new URL(raw, document.baseURI).href; } catch {}
          return raw;
        }
        function processVideoElement(video) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
          let src = video.getAttribute('src');
          if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
            _observer.disconnect();
            const absolute = toAbsoluteUrl(src);
            window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + absolute);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', absolute);
            return true;
          }
          const sources = video.getElementsByTagName('source');
          for (let source of sources) {
            src = source.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              _observer.disconnect();
              const absolute = toAbsoluteUrl(src);
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + absolute);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', absolute);
              return true;
            }
          }
        }

        function setupVideoProcessing() {
          for (const video of document.querySelectorAll("video")) {
            if (processVideoElement(video)) return;
          }
          _observer.observe(document.body, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['src']
          });
        }
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupVideoProcessing);
        } else {
          setupVideoProcessing();
        }
    """;
      scripts.add(UserScript(
        source: blobParserScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
      scripts.add(UserScript(
        source: videoTagParserScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
    }

    await webviewController?.addUserScripts(
      userScripts: scripts,
    );
  }

  @override
  Future<void> unloadPage() async {
    // init 未完成（onWebViewCreated 尚未回调）时不硬崩：
    // 空断言会把这次嗅探失败放大成未捕获异常。
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

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    try {
      final proxyAvailable =
          await android_webview.AndroidWebViewFeature.instance()
              .isFeatureSupported(WebViewFeature.PROXY_OVERRIDE);
      if (!proxyAvailable) {
        MiruLogger().w('WebView: 当前 Android 版本不支持代理');
        return;
      }

      final proxyController = android_webview.AndroidProxyController.instance();
      await proxyController.clearProxyOverride();
      await proxyController.setProxyOverride(
        settings: ProxySettings(
          proxyRules: [
            ProxyRule(url: formattedProxy),
          ],
        ),
      );
      MiruLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      MiruLogger().e('WebView: 设置代理失败 $e');
    }
  }
}

/// URL 是否应按 HLS 流处理：以 .m3u8 结尾，或路径段以 .m3u8 结尾
/// 后跟查询串（如 /index.m3u8?token=x）。
bool _isHlsUrl(String url) {
  final path = url.split('#').first.split('?').first;
  return path.endsWith('.m3u8');
}
