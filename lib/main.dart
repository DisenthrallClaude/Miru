import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:miru/app_module.dart';
import 'package:miru/app_widget.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/settings/theme_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/network/metered_network_service.dart';
import 'package:miru/services/network/proxy_manager.dart';
import 'package:miru/services/network/system_proxy_service.dart';
import 'package:miru/services/network/telemetry_service.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:miru/pages/error/storage_error_page.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:miru/utils/device.dart';
import 'package:miru/services/platform/webview_feature_service.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/navigation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (Platform.isAndroid || Platform.isIOS) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarColor: Colors.transparent,
    ));
  }

  if (Platform.isAndroid) {
    await WebViewFeatureService.initialize();
  }

  try {
    final hivePath = '${(await getApplicationSupportDirectory()).path}/hive';
    await Hive.initFlutter(hivePath);
    await GStorage.init();
    // 匿名活跃心跳（每日一次，fire-and-forget，失败静默）：
    // 为云端解析层的动态配额提供「当日活跃人数」输入
    unawaited(TelemetryService.instance.dailyPing());
    // 云端解析端点启动预热（阶段 0 / §1.4）：1.5s 健康探测把不可达
    // 端点提前熔断，首次播放不再白付 2.5s×N 延迟税。
    unawaited(CloudVideoSourceResolver.instance.warmUp());
  } catch (e) {
    // Log the error for debugging (if logger is available)
    debugPrint('Storage initialization failed: $e');

    if (isDesktop()) {
      await windowManager.ensureInitialized();
      windowManager.waitUntilReadyToShow(null, () async {
        // window_manager controls desktop visibility to avoid startup flicker.
        await windowManager.show();
        await windowManager.focus();
      });
    }
    runApp(MaterialApp(
        title: '初始化失败',
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [
          Locale.fromSubtags(
              languageCode: 'zh', scriptCode: 'Hans', countryCode: "CN")
        ],
        locale: const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hans', countryCode: "CN"),
        builder: (context, child) {
          return const StorageErrorPage();
        }));
    return;
  }
  // getSetting 为同步读取（Hive 盒已在 GStorage.init 打开），无需 await。
  final showWindowButton =
      GStorage.getSetting(SettingsKeys.showWindowButton);
  if (isDesktop()) {
    await windowManager.ensureInitialized();
    final lowResolution = await isLowResolution();
    WindowOptions windowOptions = WindowOptions(
      size: lowResolution ? const Size(840, 600) : const Size(1280, 860),
      center: true,
      skipTaskbar: false,
      // macOS always hide title bar regardless of showWindowButton setting
      titleBarStyle: (Platform.isMacOS || !showWindowButton)
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal,
      windowButtonVisibility: showWindowButton,
      title: 'Miru',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // window_manager controls desktop visibility to avoid startup flicker.
      await windowManager.show();
      await windowManager.focus();
    });
  }
  if (Platform.isWindows) {
    SystemProxyService.init();
  }
  MeteredNetworkService.init();
  // 秒开链路：本地媒体代理的预取流量守卫跟随计量网络状态。
  LocalMediaProxy.isMeteredCheck = () => MeteredNetworkService.isMetered;
  ProxyManager.applyProxy();
  runApp(
    ModularApp(
      module: appModule,
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [MiruDialog.observer, rootRouteObserver],
      defaultTransition: TransitionType.material,
      provide: (scoped) {
        scoped.addChangeNotifier<ThemeProvider>(ThemeProvider.new);
      },
      child: const AppWidget(),
    ),
  );
}
