import 'dart:async';
import 'package:webview_windows/webview_windows.dart';
import 'package:miru/webview/video/video_webview_controller.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/network/proxy_utils.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/video_source_format.dart';

class VideoWebviewWindowsImpl
    extends VideoWebviewController<WebviewController> {
  final List<StreamSubscription> subscriptions = [];

  HeadlessWebview? headlessWebview;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebview ??= HeadlessWebview();
    await headlessWebview!.run();
    await headlessWebview!.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    initEventController.add(true);
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
      await WebviewController.initializeEnvironment(
        additionalArguments: '--proxy-server=$formattedProxy',
      );
      MiruLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      MiruLogger().e('WebView: 设置代理失败 $e');
    }
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    // 防御性清理：即使调用方连续 loadUrl 未经 unloadPage，
    // 也不让旧监听重复触发回调（对齐其他平台的重复注册保护）。
    _cancelSubscriptions();
    subscriptions.add(headlessWebview!.onM3USourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      logEventController.add('Loading m3u8 source: $url');
      notifyVideoSourceResolved(
        url,
        format: VideoSourceFormat.hls,
      );
    }));
    subscriptions.add(headlessWebview!.onVideoSourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      logEventController.add('Loading video source: $url');
      notifyVideoSourceResolved(url);
    }));
    await headlessWebview!.loadUrl(url);
  }

  @override
  Future<void> unloadPage() async {
    _cancelSubscriptions();
    await redirect2Blank();
  }

  void _cancelSubscriptions() {
    for (final s in subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
  }

  @override
  Future<void> dispose() async {
    _cancelSubscriptions();
    await headlessWebview?.dispose();
    headlessWebview = null;
    disposeEventControllers();
  }

  // The webview_windows package does not have a method to unload the current page.
  // The loadUrl method opens a new tab, which can lead to memory leaks.
  // Directly disposing of the webview controller would require reinitialization when switching episodes, which is costly.
  // Therefore, this method is used to redirect to a blank page instead.
  Future<void> redirect2Blank() async {
    if (headlessWebview == null) return;
    try {
      await headlessWebview!.executeScript('''
        window.location.href = 'about:blank';
      ''');
    } catch (e) {
      MiruLogger().d('WebView: redirect2Blank skipped (likely disposed): $e');
    }
  }
}
