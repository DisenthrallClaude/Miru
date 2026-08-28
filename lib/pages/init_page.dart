import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/announcement/announcement_service.dart';
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

    // 首屏导航前的必要初始化并行化：下载记录复位与规则加载互不依赖
    // （各自读写不同的目录/盒），串行 await 会把两段磁盘 IO/解析时间
    // 叠加在空白启动页上；桌面端的 X11/快捷方式对话框也一并并行。
    // 注意：「是否首装」依赖 _pluginInit 完成（pluginList 加载后判断），
    // 因此路由决策必须等这一组 Future 全部结束。
    await Future.wait([
      _initDownloads(),
      _pluginInit(),
      _desktopStartupDialogs(),
    ]);

    // 三通道云同步延后到首屏导航后错峰触发（见 _delayedCloudSyncInit），
    // 避免全量历史同步的网络/磁盘/Hive 写锁与首屏渲染竞争。
    // 首装引导路径同样安全：未配置时各通道直接跳过。
    unawaited(_delayedCloudSyncInit());

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
    // 远程公告：主界面就绪后异步检查（内部延迟 2s 错峰 + 会话级去重）。
    // 首装引导路径不接入——刚装 App 的用户不该被运营内容打扰。
    unawaited(AnnouncementService.instance.maybeShowAnnouncement());
  }

  /// 下载控制器初始化：失败只记日志，不阻断启动路由；
  /// 后台下载导航回调仅在初始化成功后注册（与原串行流程同语义）。
  Future<void> _initDownloads() async {
    try {
      await downloadController.init();
      _setupBackgroundDownloadNavigation();
    } catch (e) {
      MiruLogger().e('InitPage: downloadController.init() failed', error: e);
    }
  }

  /// 桌面端启动对话框（X11 环境检测 / Windows 快捷方式），
  /// Android/iOS 上两个检查都是空操作；对话框之间保持原有先后顺序。
  Future<void> _desktopStartupDialogs() async {
    try {
      await _checkRunningOnX11();
      await _showShortcutDialog();
    } catch (e, stackTrace) {
      MiruLogger().w(
        'InitPage: desktop startup dialog failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 首屏导航后的云同步错峰启动：等首个有意义页面渲染稳定（约 4s）
  /// 再触发 WebDAV / GitHub 的全量历史同步与收藏合并、Bangumi 初始化，
  /// 避免与 popularCache 读取、推荐页图片加载抢 CPU/IO/网络。
  /// 各通道内部已有 try-catch，这里的兜底仅防御 Future.wait 本身。
  Future<void> _delayedCloudSyncInit() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    try {
      await Future.wait([
        _webDavInit(),
        _githubInit(),
        _bangumiInit(),
      ]);
    } catch (e, stackTrace) {
      MiruLogger().w(
        'InitPage: delayed cloud sync initialization failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
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
    final bool bangumiEnable =
        GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    if (bangumiEnable) {
      var bangumi = BangumiSyncService();
      MiruLogger().i('Bangumi: Starting Bangumi initialization');
      try {
        await bangumi.init();
      } catch (e, stackTrace) {
        // 仅当次会话禁用（reset 清掉用户名/初始化态），不再把用户的
        // bangumiSyncEnable 开关永久置 false——一次网络抖动不应让同步
        // 静默停用；下次启动会自动重试，用户也可随时在设置里手动重开。
        bangumi.reset();
        MiruLogger().w(
          'Bangumi: initialization failed, disabled for this session '
          '(will retry on next launch)',
          error: e,
          stackTrace: stackTrace,
        );
        MiruDialog.showToast(
          message: '初始化Bangumi失败，本次启动已暂停 Bangumi 同步'
              '（下次启动自动重试）：${e.toString()}',
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
