import 'dart:async';
import 'package:miru/webview/video/video_webview_controller.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/network/proxy_utils.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:miru/utils/media.dart';
import 'package:miru/webview/video/sniffed_url_filter.dart';

class VideoWebviewLinuxImpl extends VideoWebviewController<Webview> {
  bool bridgeInited = false;

  /// 当前解析器模式。回调读字段而非闭包捕获的首次值：
  /// 「超时换解析器重试」模式翻转后闭包旧值会让 iframe 分支判定失真。
  bool _useLegacyParser = false;

  @override
  Future<void> init() async {
    final proxyConfig = _getProxyConfiguration();
    webviewController ??= await WebviewWindow.create(
      configuration: CreateConfiguration(
        headless: true,
        proxy: proxyConfig,
        userScripts: const [
          UserScript(
              source: blobScript,
              injectionTime: UserScriptInjectionTime.documentStart,
              forAllFrames: true),
          UserScript(
              source: iframeScript,
              injectionTime: UserScriptInjectionTime.documentEnd,
              forAllFrames: true),
          UserScript(
              source: videoScript,
              injectionTime: UserScriptInjectionTime.documentEnd,
              forAllFrames: true)
        ],
      ),
    );
    bridgeInited = false;
    initEventController.add(true);
  }

  ProxyConfiguration? _getProxyConfiguration() {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return null;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final parsed = ProxyUtils.parseProxyUrl(proxyUrl);
    if (parsed == null) {
      return null;
    }

    final (host, port) = parsed;
    MiruLogger().i('WebView: 代理设置成功 $host:$port');
    return ProxyConfiguration(host: host, port: port);
  }

  Future<void> initBridge() async {
    await initJSBridge();
    bridgeInited = true;
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    _useLegacyParser = useLegacyParser;
    if (!bridgeInited) {
      await initBridge();
    }
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    webviewController!.launch(url);
  }

  @override
  Future<void> unloadPage() async {
    await redirect2Blank();
  }

  @override
  Future<void> dispose() async {
    webviewController?.close();
    webviewController = null;
    bridgeInited = false;
    disposeEventControllers();
  }

  Future<void> initJSBridge() async {
    webviewController!.addOnWebMessageReceivedCallback((message) async {
      if (message.contains('iframeMessage:')) {
        String messageItem =
            Uri.encodeFull(message.replaceFirst('iframeMessage:', ''));
        logEventController
            .add('Callback received: [iframe] ${Uri.decodeFull(messageItem)}');
        if ((messageItem.contains('http') || messageItem.startsWith('//')) &&
            !SniffedUrlFilter.isAdUrl(messageItem)) {
          if (decodeVideoSource(messageItem) != Uri.encodeFull(messageItem) &&
              _useLegacyParser) {
            logEventController.add('Parsing video source $messageItem');
            isIframeLoaded = true;
            isVideoSourceLoaded = true;
            logEventController
                .add('Loading video source ${decodeVideoSource(messageItem)}');
            unloadPage();
            final videoUrl = decodeVideoSource(messageItem);
            notifyVideoSourceResolved(videoUrl);
          }
        }
      }
      if (message.contains('videoMessage:')) {
        var rawUrl = message.replaceFirst('videoMessage:', '');
        // 协议相对地址（//cdn.com/x.m3u8）不含 "http" 子串，先补全，
        // 否则会被下面的 http 检查直接拒收。
        if (rawUrl.startsWith('//')) {
          rawUrl = 'https:$rawUrl';
        }
        String messageItem = Uri.encodeFull(rawUrl);
        logEventController
            .add('Callback received: [video] ${Uri.decodeFull(messageItem)}');
        if (messageItem.contains('http') &&
            !SniffedUrlFilter.isAdUrl(messageItem)) {
          String videoUrl = Uri.decodeFull(messageItem);
          logEventController.add('Loading video source: $videoUrl');
          isIframeLoaded = true;
          isVideoSourceLoaded = true;
          unloadPage();
          notifyVideoSourceResolved(videoUrl);
        }
      }
    });
  }

  static const String iframeScript = """
    var iframes = document.getElementsByTagName('iframe');
    for (var i = 0; i < iframes.length; i++) {
        var iframe = iframes[i];
        var src = iframe.getAttribute('src');
        if (src) {
          window.webkit.messageHandlers.msgToNative.postMessage('iframeMessage:' + src);
        }
    }
  """;

  static const String videoScript = """
    function processVideoElement(video) {
      let src = video.getAttribute('src');
      if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
        window.webkit.messageHandlers.msgToNative.postMessage('videoMessage:' + src);
        return;
      }
      const sources = video.getElementsByTagName('source');
      for (let source of sources) {
        src = source.getAttribute('src');
        if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
          window.webkit.messageHandlers.msgToNative.postMessage('videoMessage:' + src);
          return;
        }
      }
    }

    document.querySelectorAll('video').forEach(processVideoElement);

    const _observer = new MutationObserver((mutations) => {
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

  static const String blobScript = """
    const _r_text = window.Response.prototype.text;
    window.Response.prototype.text = function () {
        return new Promise((resolve, reject) => {
            _r_text.call(this).then((text) => {
                resolve(text);
                if (text.trim().startsWith("#EXTM3U")) {
                    window.webkit.messageHandlers.msgToNative.postMessage('videoMessage:' + this.url);
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
                    // 站点可能给相对地址；按页面 baseURI 补全后再上抛。
                    let requestUrl = args[1];
                    try { requestUrl = new URL(requestUrl, document.baseURI).href; } catch {}
                    window.webkit.messageHandlers.msgToNative.postMessage('videoMessage:' + requestUrl);
                };
            } catch { }
        });
        return _open.apply(this, args);
    }
  """;

  Future<void> redirect2Blank() async {
    webviewController?.launch("about:blank");
  }
}
