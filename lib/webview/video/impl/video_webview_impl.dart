import 'dart:async';
import 'dart:ui';
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

class VideoWebviewImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;
  bool hasRegisteredHandlers = false;
  bool useLegacyParser = false;
  Timer? videoParserTimer;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialSize: const Size(360, 640),
        initialSettings: InAppWebViewSettings(
          // 与 mpv 播放共用会话 UA：解析与播放必须同源，否则防盗链 CDN 拒播
          userAgent: getSessionUA(),
          mediaPlaybackRequiresUserGesture: true,
          upgradeKnownHostsToHTTPS: false,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        ),
        onWebViewCreated: (controller) {
          MiruLogger().i('[WebView] Created (legacy fallback)');
          webviewController = controller;
          initEventController.add(true);
        },
        shouldInterceptRequest: (controller, request) async {
          if (useLegacyParser || isVideoSourceLoaded) return null;
          final url = request.url.toString();
          final lower = url.toLowerCase();
          if (SniffedUrlFilter.isAdUrl(lower)) return null;
          if (_isM3U8Url(lower) ||
              _isRangeVideoRequest(lower, request.headers)) {
            logEventController.add('Native intercepted video URL: $url');
            isIframeLoaded = true;
            isVideoSourceLoaded = true;
            unloadPage();
            notifyVideoSourceResolved(url);
          }
          return null;
        },
        onLoadStart: (controller, url) async {
          logEventController.add('started loading: $url');
          if (url.toString() != 'about:blank') {
            await _onLoadStart();
          }
        },
        onLoadStop: (controller, url) async {
          logEventController.add('loading completed: $url');
          if (url.toString() != 'about:blank') {
            await _onLoadStop();
          }
        },
        onConsoleMessage: (controller, consoleMessage) {
          logEventController.add(
              'Console [${consoleMessage.messageLevel}]: ${consoleMessage.message}');
        },
        onReceivedError: (controller, request, error) {
          logEventController
              .add('Error: ${error.description} - ${request.url}');
        },
      ),
    );
    await headlessWebView?.run();
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    // 两套桥 handler 常驻注册：本实现的脚本注入时机（onLoadStart/
    // onLoadStop）始终跟随本次 loadUrl 的模式，若 handler 仍停留在首次
    // 注册的那套，换解析器重试时脚本会调用未注册的 handler 而必然超时。
    if (!hasRegisteredHandlers) {
      _addJavaScriptHandlers();
      hasRegisteredHandlers = true;
    }
    this.offset = offset;
    this.useLegacyParser = useLegacyParser;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;

    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// 两套桥 handler 都常驻注册（LogBridge + JSBridgeDebug +
  /// VideoBridgeDebug）：脚本按解析器模式只调用其一。
  void _addJavaScriptHandlers() {
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

  /// URL 是否应按 HLS 流处理：以 .m3u8 结尾，或 .m3u8 后跟查询串。
  bool _isHlsUrl(String url) {
    final path = url.split('#').first.split('?').first;
    return path.endsWith('.m3u8');
  }

  Future<void> _onLoadStart() async {
    if (!useLegacyParser) {
      logEventController.add('Injecting blob parser script (onLoadStart)');
      await webviewController?.evaluateJavascript(source: """
        try { window.flutter_inappwebview.callHandler('LogBridge', 'BlobParser script loaded: ' + window.location.href); } catch(e) {}
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

        function injectIntoIframe(iframe) {
          try {
            const iframeWindow = iframe.contentWindow;
            if (!iframeWindow) return;

            const iframe_r_text = iframeWindow.Response.prototype.text;
            iframeWindow.Response.prototype.text = function () {
              return new Promise((resolve, reject) => {
                iframe_r_text.call(this).then((text) => {
                  resolve(text);
                  if (text.trim().startsWith("#EXTM3U")) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in iframe: ' + this.url);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                  }
                }).catch(reject);
              });
            }

            const iframe_open = iframeWindow.XMLHttpRequest.prototype.open;
            iframeWindow.XMLHttpRequest.prototype.open = function (...args) {
              this.addEventListener("load", () => {
                try {
                  let content = this.responseText;
                  if (content.trim().startsWith("#EXTM3U") && args[1] !== null && args[1] !== undefined) {
                    // 相对地址按 iframe 自身 baseURI 补全后再上抛。
                    let requestUrl = args[1];
                    try { requestUrl = new URL(requestUrl, iframeWindow.document.baseURI).href; } catch {}
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in iframe: ' + requestUrl);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', requestUrl);
                  };
                } catch {}
              });
              return iframe_open.apply(this, args);
            }
          } catch (e) {
            console.error('iframe inject failed:', e);
          }
        }

        function setupIframeListeners() {
          document.querySelectorAll('iframe').forEach(iframe => {
            if (iframe.contentDocument) {
              injectIntoIframe(iframe);
            }
            iframe.addEventListener('load', () => injectIntoIframe(iframe));
          });

          const observer = new MutationObserver(mutations => {
            mutations.forEach(mutation => {
              if (mutation.type === 'childList') {
                mutation.addedNodes.forEach(node => {
                  if (node.nodeName === 'IFRAME') {
                    node.addEventListener('load', () => injectIntoIframe(node));
                  }
                  if (node.querySelectorAll) {
                    node.querySelectorAll('iframe').forEach(iframe => {
                      iframe.addEventListener('load', () => injectIntoIframe(iframe));
                    });
                  }
                });
              }
            });
          });

          if (document.body) {
            observer.observe(document.body, { childList: true, subtree: true });
          } else {
            document.addEventListener('DOMContentLoaded', () => {
              observer.observe(document.body, { childList: true, subtree: true });
            });
          }
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupIframeListeners);
        } else {
          setupIframeListeners();
        }
      """);
    }
  }

  Future<void> _onLoadStop() async {
    if (!useLegacyParser) {
      logEventController.add('Injecting video tag parser script (onLoadStop)');
      await webviewController?.evaluateJavascript(source: """
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
        function processVideoElement(video) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
          let src = video.getAttribute('src');
          if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
            _observer.disconnect();
            window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
            return true;
          }
          const sources = video.getElementsByTagName('source');
          for (let source of sources) {
            src = source.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              _observer.disconnect();
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
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
      """);
    }

    if (useLegacyParser) {
      logEventController.add('Injecting JSBridgeDebug script (onLoadStop)');
      await webviewController?.evaluateJavascript(source: """
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
      """);
    }

    _startVideoParserTimer();
  }

  void _startVideoParserTimer() {
    videoParserTimer?.cancel();
    logEventController.add('Starting video parser timer');
    videoParserTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (isVideoSourceLoaded) {
        timer.cancel();
        return;
      }
      _pollVideoSource();
    });
  }

  Future<void> _pollVideoSource() async {
    if (isVideoSourceLoaded) return;

    if (useLegacyParser) {
      await webviewController?.evaluateJavascript(source: """
        (function() {
          var iframes = document.querySelectorAll('iframe');
          window.flutter_inappwebview.callHandler('LogBridge', 'Timer scan: found ' + iframes.length + ' iframe(s)');
          for (var i = 0; i < iframes.length; i++) {
            var src = iframes[i].getAttribute('src');
            if (src) {
              window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
            }
          }
        })();
      """);
    } else {
      await webviewController?.evaluateJavascript(source: """
        (function() {
          var videos = document.querySelectorAll('video');
          window.flutter_inappwebview.callHandler('LogBridge', 'Timer scan: found ' + videos.length + ' video element(s)');
          for (var i = 0; i < videos.length; i++) {
            var src = videos[i].getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
              return;
            }
            var sources = videos[i].getElementsByTagName('source');
            for (var j = 0; j < sources.length; j++) {
              src = sources[j].getAttribute('src');
              if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
                window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
                window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
                return;
              }
            }
          }
        })();
      """);
    }
  }

  @override
  Future<void> unloadPage() async {
    videoParserTimer?.cancel();
    videoParserTimer = null;
    await webviewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri("about:blank")));
  }

  @override
  Future<void> dispose() async {
    videoParserTimer?.cancel();
    videoParserTimer = null;
    await headlessWebView?.dispose();
    headlessWebView = null;
    webviewController = null;
    disposeEventControllers();
  }

  bool _isM3U8Url(String lower) {
    final uri = Uri.tryParse(lower);
    if (uri == null) return false;
    return uri.path.endsWith('.m3u8');
  }

  bool _isRangeVideoRequest(String lower, Map<String, String>? headers) {
    if (headers == null) return false;
    final range = headers['Range'] ?? headers['range'];
    if (range == null || !range.startsWith('bytes=')) return false;
    // 带 Range 的请求并不都是媒体：静态资源与常见数据接口
    // （字幕 .vtt/.srt、站点地图 .xml、字体、播放器清单等）一律放行。
    const nonMediaExtensions = [
      '.js', '.mjs', '.css', '.html', '.htm', '.json', '.xml', '.txt',
      '.map', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico',
      '.woff', '.woff2', '.ttf', '.otf', '.eot', '.wasm', '.vtt', '.srt',
    ];
    for (final ext in nonMediaExtensions) {
      if (lower.endsWith(ext)) return false;
    }
    return true;
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
