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

/// Android WebView 视频嗅探实现（阶段 0 / §1.5 全面升级）。
///
/// 与旧版的差异：
/// - **两套脚本合并注入**：legacy iframe 观察脚本与 blob/XHR/videoTag
///   脚本一次全部注入，`useLegacyParser` 只影响候选优先级，不再翻转
///   注入（翻转即伪重试的根因）；
/// - **网络层嗅探（Dart 侧）**：onLoadResource + shouldInterceptRequest
///   对 URL 直接判定（分片/索引扩展名），arraybuffer XHR / 原生 video
///   请求不再漏；shouldInterceptRequest 顺带捕获 Referer/Origin/Cookie；
/// - **ContentBlocker**：图片/字体/样式 + 广告统计域全 BLOCK；
/// - **缓存与媒体设置**：cacheEnabled=true（播放器 JS 不重下）、
///   mediaPlaybackRequiresUserGesture=false（播放器可以自动请求 m3u8）；
/// - **嗅探成功即冻结**：loadUrl(about:blank) + pauseTimers()，页面
///   不再继续烧流量；下次 loadUrl 前 resumeTimers()。
class VideoWebviewAndroidImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;

  /// 定时器是否处于暂停态（pauseTimers 后置 true）。
  bool _timersPaused = false;

  // ---------------------------------------------------------------------------
  // 初始化
  // ---------------------------------------------------------------------------

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialSettings: _buildSettings(),
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
        // 网络层嗅探（§1.5）：任何资源请求都过一遍 URL 判定。
        onLoadResource: (controller, resource) {
          _maybeSniffNetworkUrl(resource.url?.toString() ?? '');
        },
        shouldInterceptRequest: (controller, request) async {
          // 只判定、不改写响应（返回 null 让 WebView 正常加载），
          // 同时把请求头里的 Referer/Origin/Cookie 捕获给播放头。
          _maybeSniffNetworkUrl(
            request.url.toString(),
            requestHeaders: request.headers,
          );
          return null;
        },
      ),
    );
    await headlessWebView?.run();
  }

  /// WebView 设置（§1.5 全套）。
  InAppWebViewSettings _buildSettings() {
    return InAppWebViewSettings(
      // 与 mpv 播放共用会话 UA：解析与播放必须同源，否则防盗链 CDN 拒播
      userAgent: getSessionUA(),
      // §1.5：部分播放器（Artplayer/DPlayer 等）在无人手势时永不发起
      // m3u8 请求——headless 嗅探根本等不到网络请求。放开后页面可以
      // 自动起播，我们 muted 自动播放后立刻嗅探冻结，不会有声音外放。
      mediaPlaybackRequiresUserGesture: false,
      // §1.5：开启 HTTP 缓存——播放器 JS（几百 KB 且经常带版本号）
      // 二次嗅探不再重下，直接缩短 WebView 兜底 30~50% 耗时。
      cacheEnabled: true,
      cacheMode: CacheMode.LOAD_DEFAULT,
      // §1.5：JS 站的 window.open 弹窗都是广告，全部拒绝。
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: false,
      blockNetworkImage: true,
      loadsImagesAutomatically: false,
      useOnLoadResource: true,
      useShouldInterceptRequest: true,
      allowsInlineMediaPlayback: true,
      thirdPartyCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: false,
      // headless 无渲染面：GPU 加速纯属浪费电量。
      hardwareAcceleration: false,
      upgradeKnownHostsToHTTPS: false,
      safeBrowsingEnabled: false,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
      geolocationEnabled: false,
      // §1.5 ContentBlocker：资源型拦截（图片/字体/样式/SVG）省带宽，
      // 媒体放行（嗅探靠它）；广告/统计域全类型拦截。
      contentBlockers: _buildContentBlockers(),
    );
  }

  List<ContentBlocker> _buildContentBlockers() {
    final blockers = <ContentBlocker>[
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*', resourceType: [
          ContentBlockerTriggerResourceType.IMAGE,
          ContentBlockerTriggerResourceType.FONT,
          ContentBlockerTriggerResourceType.STYLE_SHEET,
          ContentBlockerTriggerResourceType.SVG_DOCUMENT,
        ]),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
    ];
    for (final domain in _adStatDomains) {
      blockers.add(ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: domain,
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ));
    }
    return blockers;
  }

  /// 广告/统计域（§1.5）：WebView 层直接拒载，省时省流量。
  static const List<String> _adStatDomains = [
    r'^https?://.+?google-analytics\.com',
    r'^https?://.+?googletagmanager\.com',
    r'^https?://.+?doubleclick\.net',
    r'^https?://.+?googlesyndication\.com',
    r'^https?://.+?baidu\.com/hm\.js',
    r'^https?://.+?cnzz\.com',
    r'^https?://.+?51\.la',
    r'^https?://.+?umeng\.com',
    r'^https?://.+?clarity\.ms',
    r'^https?://.+?adsco\.re',
    r'^https?://.+?prestrain\.html',
    r'^https?://.+?devtools-detector\.js',
  ];

  // ---------------------------------------------------------------------------
  // 页面加载与脚本注入
  // ---------------------------------------------------------------------------

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    // 两套脚本一次性全量注入（§1.5）——不再按 useLegacyParser 翻换注入。
    // 首次注入后常驻；useLegacyParser 仅影响 JSBridgeDebug(iframe) 结果
    // 与 VideoBridgeDebug(媒体) 结果的优先级，由上层处理。
    if (!_scriptsInjected) {
      addJavaScriptHandlers();
      await _injectAllUserScripts();
      _scriptsInjected = true;
    }
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;

    // 上次嗅探成功后定时器被冻结（§1.5）：恢复后才能加载新页面。
    if (_timersPaused) {
      try {
        await webviewController?.resumeTimers();
      } catch (_) {}
      _timersPaused = false;
    }

    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// 脚本是否已注入（进程内只需一次；[unloadPage] 不清脚本）。
  bool _scriptsInjected = false;

  Future<void> _injectAllUserScripts() async {
    final List<UserScript> scripts = _buildAllUserScripts();
    await webviewController?.addUserScripts(userScripts: scripts);
  }

  /// 两套嗅探脚本 + 新 JS 钩子合并注入（§1.5）。
  List<UserScript> _buildAllUserScripts() {
    logEventController.add('Injecting all sniffer scripts (merged)');
    final scripts = <UserScript>[];

    // ---- 1) legacy iframe 观察脚本（MacCMS 播放器 iframe 结构）----
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
      // 跨域 iframe 播放器也必须被注入：显式钉死 false。
      forMainFrameOnly: false,
    ));

    // ---- 2) blob/XHR m3u8 文本嗅探 ----
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
    scripts.add(UserScript(
      source: blobParserScript,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
    ));

    // ---- 3) video 标签嗅探 + media src setter 劫持 + 自动静音起播 ----
    const String videoTagParserScript = """
      window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);

      // §1.5：HTMLMediaElement.src setter 劫持——动态播放器（p2p 播放器/
      // MSE 混合型）先赋 src 再 load()，MutationObserver 属性过滤抓不到
      // setter 路径的赋值，劫持后 src 一被设置即上报。
      try {
        const _origSrcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (_origSrcDesc && _origSrcDesc.set) {
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            set(v) {
              try {
                if (v && typeof v === 'string' && v.startsWith('http')) {
                  window.flutter_inappwebview.callHandler('LogBridge', 'Media src set: ' + v);
                  window.flutter_inappwebview.callHandler('VideoBridgeDebug', v);
                }
              } catch {}
              return _origSrcDesc.set.call(this, v);
            },
            get() { return _origSrcDesc.get.call(this); },
            configurable: true,
          });
        }
      } catch {}

      // §1.5：createObjectURL 只记录 MSE 使用，不报 blob（blob 无 referer
      // 且无法直接播放），让网络层嗅探去抓真正的分片请求。
      try {
        const _cou = URL.createObjectURL;
        URL.createObjectURL = function(o) {
          try {
            window.flutter_inappwebview.callHandler('LogBridge', 'createObjectURL called (MSE in use)');
          } catch {}
          return _cou(o);
        };
      } catch {}

      const _observer = new MutationObserver((mutations) => {
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
        try { return new URL(raw, document.baseURI).href; } catch {}
        return raw;
      }
      function processVideoElement(video) {
        window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
        // §1.5：新出现的 video 自动静音起播——mediaPlaybackRequiresUserGesture
        // 已放开，但部分播放器仍等手势；静音 play 触发其内部网络请求，
        // 嗅探成功立刻冻结页面，不会外放。
        try {
          if (!video.muted) video.muted = true;
          const p = video.play();
          if (p && p.catch) p.catch(() => {});
        } catch {}
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
        return false;
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
      source: videoTagParserScript,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
    ));

    // ---- 4) 播放防外放 + 播放大按钮代点（§1.5）----
    const String antiNoiseScript = """
      window.flutter_inappwebview.callHandler('LogBridge', 'AntiNoise script loaded: ' + window.location.href);
      // 防外放：某些第三方播放器初始化 AudioContext 试音。
      try {
        const _AC = window.AudioContext;
        if (_AC) {
          window.AudioContext = function() {
            return { resume(){}, close(){}, createGain(){ return { connect(){} }; },
                     createBufferSource(){ return { connect(){}, start(){} }; },
                     destination: {} };
          };
          window.AudioContext.prototype = _AC.prototype;
        }
      } catch {}
      // 延迟 800ms 点一次播放大按钮：大量 JS 站的播放器把真实网络请求
      // 藏在「用户点播放」之后，代点后请求才发出。
      setTimeout(() => {
        try {
          document.querySelectorAll(
            '.dplayer-play-icon,.art-video-player,.vjs-big-play-button,.prism-big-play-btn,#playButton'
          ).forEach(e => { try { e.click(); } catch {} });
        } catch {}
      }, 800);
    """;
    scripts.add(UserScript(
      source: antiNoiseScript,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
      forMainFrameOnly: false,
    ));

    return scripts;
  }

  /// 两套桥 handler 常驻注册（注入脚本同时调用两套，
  /// 常驻可避免「换解析器重试后脚本调用了未注册的 handler」而必然超时）。
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
          if ((message.contains('http') || message.startsWith('//')) &&
              !SniffedUrlFilter.isAdUrl(message)) {
            logEventController.add('Parsing video source $message');
            String encodedUrl = Uri.encodeFull(message);
            if (decodeVideoSource(encodedUrl) != encodedUrl) {
              isIframeLoaded = true;
              isVideoSourceLoaded = true;
              logEventController.add(
                  'Loading video source ${decodeVideoSource(encodedUrl)}');
              _freezeAfterSniffSuccess();
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
            _freezeAfterSniffSuccess();
            // 嗅探到的 .m3u8 显式标注 HLS：mpv 侧据此强制
            // demuxer-lavf-format=hls，避开内容探测失误。
            notifyVideoSourceResolved(
              message,
              format: _isHlsUrl(message)
                  ? VideoSourceFormat.hls
                  : VideoSourceFormat.auto,
            );
          }
        });
  }

  // ---------------------------------------------------------------------------
  // 网络层嗅探（§1.5，Dart 侧）
  // ---------------------------------------------------------------------------

  /// onLoadResource / shouldInterceptRequest 共用的 URL 判定：
  /// 路径带视频扩展、或 playlist 型 m3u8 路径、或 query 含 .m3u8；
  /// 排除广告/统计域。命中即上报（带网络层捕获的请求头）。
  void _maybeSniffNetworkUrl(String url, {Map<String, String>? requestHeaders}) {
    if (isVideoSourceLoaded) return;
    if (url.isEmpty || !url.startsWith('http')) return;
    if (SniffedUrlFilter.isAdUrl(url)) return;
    if (!_isSniffableMediaUrl(url)) return;
    // 本地代理/自身请求不嗅探
    if (url.contains('127.0.0.1')) return;

    logEventController.add('Network sniff: $url');
    isIframeLoaded = true;
    isVideoSourceLoaded = true;
    _freezeAfterSniffSuccess();

    // 网络层捕获的请求头：Referer 是防盗链的关键（源站要求播放请求带
    // 同一 Referer），Origin/Cookie 备用。键名统一小写。
    final headers = <String, String>{};
    requestHeaders?.forEach((k, v) {
      final lower = k.toLowerCase();
      if (lower == 'referer' || lower == 'origin' || lower == 'cookie') {
        headers[lower == 'origin' ? 'referer' : lower] = v;
      }
    });

    notifyVideoSourceResolved(
      url,
      format: _isHlsUrl(url) ? VideoSourceFormat.hls : VideoSourceFormat.auto,
      headers: headers.isEmpty ? null : headers,
    );
  }

  /// 媒体 URL 判定（网络层嗅探用）。
  static final RegExp _mediaExtRe = RegExp(
      r'\.(m3u8|mp4|flv|mkv|mov|webm)(\?|$)',
      caseSensitive: false);

  static bool _isSniffableMediaUrl(String url) {
    final lower = url.toLowerCase();
    final path = lower.split('#').first.split('?').first;
    if (_mediaExtRe.hasMatch(path)) return true;
    // /index.m3u8 / /playlist.m3u8 / mixed 型清单路径
    if (RegExp(r'/(index|mixed|playlist|hls)[^/]*\.m3u8').hasMatch(path)) {
      return true;
    }
    // query 里带 .m3u8（如 /api.php?type=m3u8 或 ?url=xx.m3u8）
    final query = lower.split('#').first.split('?').skip(1).join('?');
    if (query.contains('.m3u8')) return true;
    return false;
  }

  /// 嗅探成功后冻结页面（§1.5）：转空白页 + 暂停 JS 定时器，
  /// 页面不再继续烧流量/CPU。下次 [loadUrl] 会 [resumeTimers]。
  void _freezeAfterSniffSuccess() {
    unawaited(_freezeAfterSniffSuccessAsync());
  }

  Future<void> _freezeAfterSniffSuccessAsync() async {
    try {
      await unloadPage();
    } catch (_) {}
    try {
      await webviewController?.pauseTimers();
      _timersPaused = true;
    } catch (e) {
      MiruLogger().d('WebView: pauseTimers failed', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

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
    _scriptsInjected = false;
    _timersPaused = false;
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

/// 纯函数测试探针（阶段 0 单测）。
class VideoWebviewAndroidImplProbe {
  /// 网络层嗅探的媒体 URL 判定。
  static bool isSniffableMediaUrl(String url) =>
      VideoWebviewAndroidImpl._isSniffableMediaUrl(url);
}
