import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/plugin/community_rules_sync.dart';
import 'package:miru/pages/my/my_controller.dart';
import 'package:miru/services/sync/bangumi_sync_service.dart';
import 'package:miru/services/sync/github_sync.dart';
import 'package:miru/services/sync/webdav.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/collect/collect_controller.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/metered_network_service.dart';
import 'package:miru/services/shaders/shader_asset_service.dart';
import 'package:miru/pages/download/download_controller.dart';
import 'package:miru/pages/plugin_editor/plugin_update_actions.dart';
import 'package:miru/services/download/background_download_service.dart';
import 'package:miru/services/platform/windows_shortcut.dart';
import 'package:miru/services/platform/platform_environment_service.dart';
import 'package:miru/services/update/startup_update_check.dart';
import 'package:miru/navigation.dart';

class InitPage extends StatefulWidget {
  const InitPage({
    super.key,
    required this.pluginsController,
    required this.collectController,
    required this.shaderAssetService,
    required this.myController,
    required this.downloadController,
  });

  final PluginsController pluginsController;
  final CollectController collectController;
  final ShaderAssetService shaderAssetService;
  final MyController myController;
  final DownloadController downloadController;

  @override
  State<InitPage> createState() => _InitPageState();
}

class _InitPageState extends State<InitPage> {
  PluginsController get pluginsController => widget.pluginsController;
  CollectController get collectController => widget.collectController;
  ShaderAssetService get shaderAssetService => widget.shaderAssetService;
  MyController get myController => widget.myController;
  DownloadController get downloadController => widget.downloadController;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeApp());
  }

  Future<void> _initializeApp() async {
    _migrateStorage();
    _loadShaders();
    _loadDanmakuShield();
    _webDavInit();
    _githubInit();
    _bangumiInit();
    try {
      await downloadController.init();
      _setupBackgroundDownloadNavigation();
    } catch (e) {
      MiruLogger().e('InitPage: downloadController.init() failed', error: e);
    }

    await _checkRunningOnX11();
    await _showShortcutDialog();
    await _pluginInit();

    if (!mounted) {
      return;
    }
    // First launch: no installed rules yet, hand over to the onboarding flow.
    // OnboardingPage takes care of navigating to the default page and
    // triggering the auto update check afterwards.
    if (pluginsController.pluginList.isEmpty) {
      context.navigate('/onboarding');
      return;
    }

    if (!mounted) {
      return;
    }
    final updateController = myController;
    unawaited(runStartupUpdateCheck(
      isEnabled: () => GStorage.getSetting(SettingsKeys.autoUpdate),
      checkForUpdate: () async {
        await updateController.checkUpdate(type: 'auto');
      },
    ));
    _startDefaultPage();
  }

  void _setupBackgroundDownloadNavigation() {
    final backgroundService = BackgroundDownloadService();

    backgroundService.onNavigateToDownloadRequested = () {
      Future.delayed(const Duration(milliseconds: 300), () {
        try {
          final navigationContext = rootNavigatorKey.currentContext;
          if (navigationContext == null || !navigationContext.mounted) return;
          final path = navigationContext.routeState(listen: false).uri.path;
          if (path.contains('/download')) return;
          navigationContext.pushNamed('/settings/download/');
        } catch (e) {
          MiruLogger()
              .w('InitPage: failed to navigate to download page', error: e);
        }
      });
    };

    backgroundService.onNotificationPermissionRequired = () async {
      final result = await MiruDialog.show<bool>(
        clickMaskDismiss: false,
        builder: (context) {
          return AlertDialog(
            title: const Text('需要通知权限'),
            content: const Text(
              '开启通知权限后，可以在后台下载时显示进度，并防止系统终止下载任务。\n\n'
              '如果拒绝，下载功能仍可使用，但在后台时可能被系统中断。',
            ),
            actions: [
              TextButton(
                onPressed: () => MiruDialog.dismiss(popWith: false),
                child: Text(
                  '稍后再说',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              TextButton(
                onPressed: () => MiruDialog.dismiss(popWith: true),
                child: const Text('允许'),
              ),
            ],
          );
        },
      );
      return result ?? false;
    };
  }

  void _startDefaultPage() {
    final defaultStartupPage =
        GStorage.getSetting(SettingsKeys.defaultStartupPage);
    if (!mounted) {
      return;
    }
    context.navigate(defaultStartupPage);
  }

  // migrate collect from old version (favorites)
  Future<void> _migrateStorage() async {
    await collectController.migrateCollect();
  }

  Future<void> _loadShaders() async {
    await shaderAssetService.copyShadersToExternalDirectory();
  }

  Future<void> _loadDanmakuShield() async {
    myController.loadShieldList();
  }

  Future<void> _webDavInit() async {
    bool webDavEnable = await GStorage.getSetting(SettingsKeys.webDavEnable);
    if (webDavEnable) {
      var webDav = WebDav();
      MiruLogger().i('WebDav: Starting WebDav initialization');
      try {
        await webDav.init();
        try {
          await webDav.syncHistory();
          MiruLogger().i('WebDav: Completed syncing watch history');
        } catch (e, stackTrace) {
          MiruLogger().w(
            'WebDav: automatic watch history sync failed',
            error: e,
            stackTrace: stackTrace,
          );
        }
      } catch (e, stackTrace) {
        MiruLogger().w(
          'WebDav: automatic initialization failed',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> _githubInit() async {
    final bool githubEnable = GStorage.getSetting(SettingsKeys.githubEnable);
    if (!githubEnable) {
      return;
    }
    final github = GithubSync();
    MiruLogger().i('GithubSync: starting initialization');
    try {
      await github.init();
      try {
        if (GStorage.getSetting(SettingsKeys.githubEnableHistory)) {
          await github.syncHistory();
          MiruLogger().i('GithubSync: completed syncing watch history');
        }
        if (GStorage.getSetting(SettingsKeys.githubEnableCollect)) {
          await github.syncCollectibles();
          MiruLogger().i('GithubSync: completed syncing collectibles');
        }
      } catch (e, stackTrace) {
        MiruLogger().w(
          'GithubSync: automatic sync failed',
          error: e,
          stackTrace: stackTrace,
        );
      }
    } catch (e, stackTrace) {
      MiruLogger().w(
        'GithubSync: automatic initialization failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _bangumiInit() async {
    bool bangumiEnable =
        await GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    if (bangumiEnable) {
      var bangumi = BangumiSyncService();
      MiruLogger().i('Bangumi: Starting Bangumi initialization');
      try {
        await bangumi.init();
      } catch (e) {
        bangumi.reset();
        await GStorage.putSetting(SettingsKeys.bangumiSyncEnable, false);
        MiruLogger().w(
          'Bangumi: initialization failed, disabling Bangumi sync until user re-enables it',
          error: e,
        );
        MiruDialog.showToast(
          message: '初始化Bangumi失败，已关闭 Bangumi 同步: ${e.toString()}',
        );
      }
    }
  }

  Future<void> _checkRunningOnX11() async {
    if (!Platform.isLinux) {
      return;
    }
    bool isRunningOnX11 = await PlatformEnvironmentService.isRunningOnX11();
    if (isRunningOnX11) {
      await MiruDialog.show(
        clickMaskDismiss: false,
        builder: (context) {
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('X11环境检测'),
              content: const Text(
                  '检测到您当前运行在X11环境下，Miru在X11环境下可能出现性能问题或界面异常，建议切换到Wayland以获得更好的体验。您是否希望在X11下继续使用Miru？'),
              actions: [
                TextButton(
                  onPressed: () {
                    exit(0);
                  },
                  child: Text(
                    '退出',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    MiruDialog.dismiss();
                  },
                  child: const Text('继续'),
                ),
              ],
            ),
          );
        },
      );
    }
  }

  Future<void> _showShortcutDialog() async {
    if (!Platform.isWindows) return;
    if (GStorage.getSetting(SettingsKeys.shortcutDialogShown)) {
      return;
    }

    final create = await MiruDialog.show<bool>(
      clickMaskDismiss: false,
      builder: (context) => AlertDialog(
        title: const Text('创建桌面快捷方式'),
        content: const Text('是否在桌面创建 Miru 的快捷方式？'),
        actions: [
          TextButton(
            onPressed: () => MiruDialog.dismiss(popWith: false),
            child: Text('暂不创建',
                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ),
          TextButton(
            onPressed: () => MiruDialog.dismiss(popWith: true),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    await GStorage.putSetting(SettingsKeys.shortcutDialogShown, true);
    if (create ?? false) {
      final success = await WindowsShortcut.createDesktopShortcut();
      MiruDialog.showToast(message: success ? '桌面快捷方式已创建' : '桌面快捷方式创建失败');
    }
  }

  Future<void> _pluginInit() async {
    try {
      await pluginsController.init();
      unawaited(_pluginUpdate());
    } catch (error, stackTrace) {
      MiruLogger().e(
        'Plugin: failed to initialize rules',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _pluginUpdate() async {
    final checkOnStartup =
        GStorage.getSetting(SettingsKeys.checkPluginUpdateOnStartup);
    // 移动数据下跳过启动检查：规则目录与批量更新都会产生流量，
    // 用户没有主动操作时不该消耗套餐；回到 WiFi 后下次启动照常。
    if (checkOnStartup && MeteredNetworkService.isMetered) {
      MiruLogger().i('Plugin: skip startup update check on metered network');
      return;
    }
    late final int count;
    try {
      count = await pluginsController.checkPluginUpdatesOnStartup(
        enabled: checkOnStartup,
      );
    } catch (_) {
      return;
    }
    if (count != 0) {
      MiruDialog.showToast(
        message: '检测到 $count 条规则可以更新',
        showActionButton: true,
        actionLabel: '全部更新',
        onActionPressed: () => updateAllPluginsWithFeedback(
          pluginsController,
          ensureCatalog: false,
        ),
        duration: const Duration(seconds: 5),
      );
    }
    // 社区规则仓库静默同步：与规则商店目录互补，站点改版后
    // 由社区贡献者当天跟进的修复直接落到本地，无需用户操作。
    unawaited(CommunityRulesSync.sync());
  }

  @override
  Widget build(BuildContext context) {
    return const LoadingWidget();
  }
}

class LoadingWidget extends StatelessWidget {
  const LoadingWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Container());
  }
}
