import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/announcement/announcement_service.dart';
import 'package:miru/pages/my/my_controller.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_theme.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_welcome.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/plugins/rule_policy.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/startup/startup_gate.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/update/startup_update_check.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// 首次启动引导页 —— 液态玻璃欢迎屏。
///
/// v1.6.1 起不再有「同意声明 / 更新来源 / 网络镜像」的多步选择：
/// 一切默认同意并自动安装（免责声明视为已同意，镜像开关默认启用，
/// 内置规则随首次进入自动安装；日漫与失效源依旧留给设置页按需安装）。
///
/// v1.6.3 双模式：
///  * 首启动（onboardingDone=false）：上述自动安装流程，完成时写入
///    onboardingDone 标志；
///  * 重播（onboardingDone=true，设置里开了「每次启动显示开屏」）：
///    只播开屏特效，不重跑安装/写设置；进入时等 StartupGate 放行，
///    返回键 = 跳过开屏直接进主界面（不再弹退出确认）。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.pluginsController,
    required this.myController,
  });

  final PluginsController pluginsController;
  final MyController myController;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  /// 自动配置过程中的进度文案（null 表示未在自动配置）。
  String? autoSetupMessage;

  /// v1.6.3：是否重播模式（首启动已完成，只为再播一次开屏）。
  late final bool replayMode =
      GStorage.getSetting(SettingsKeys.onboardingDone);

  PluginsController get pluginsController => widget.pluginsController;

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    final theme = liquidGlassThemeFor(brightness);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (replayMode) {
          // 重播模式：返回 = 跳过开屏直接进主界面（不是退出应用）。
          unawaited(_enterFromSplash());
          return;
        }
        _confirmExit();
      },
      child: Scaffold(
        backgroundColor: theme.pageColor,
        body: Stack(
          children: [
            LiquidGlassWelcome(
              theme: theme,
              onEnter: () => unawaited(replayMode
                  ? _enterFromSplash()
                  : _autoSetupAndFinish(openGithub: false)),
              onEnterViaGithub: () => unawaited(replayMode
                  ? _enterFromSplash(viaGithub: true)
                  : _autoSetupAndFinish(openGithub: true)),
            ),
            if (autoSetupMessage != null) _buildSetupOverlay(),
          ],
        ),
      ),
    );
  }

  /// 自动配置遮罩：全屏轻雾 + 进度文案，防止误触与「卡死」观感。
  Widget _buildSetupOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  autoSetupMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v1.6.3：重播模式的进入动作。
  ///
  /// 不重跑首次安装（规则已就绪、设置已同意）；只等后台初始化完成
  ///（StartupGate，秒级放行）后进入默认页。
  Future<void> _enterFromSplash({bool viaGithub = false}) async {
    if (autoSetupMessage != null) return; // 防重复点击。
    if (viaGithub) {
      unawaited(_openRepository());
    }
    // 等待后台初始化（通常已完成，瞬间放行）；未完成时给轻雾进度。
    final pending = !StartupGate.isReady;
    if (pending && mounted) {
      setState(() => autoSetupMessage = '正在完成启动准备…');
    }
    await StartupGate.pluginsReady();
    if (!mounted) return;
    if (pending) {
      setState(() => autoSetupMessage = null);
    }
    _finish(replay: true);
  }

  /// 默认同意 + 自动完成：内置规则落盘 →（可选 GitHub 入口）→ 启用网络镜像
  /// → 拉取规则目录 → 逐条安装 → 进入主界面。
  ///
  /// 原流程需要用户在「免责声明」「更新源」「网络镜像」「规则商店」
  /// 多页里反复确认并手动逐条安装；这里一次性做完，不再询问。
  ///
  /// 日漫为主的规则与已知损坏的规则不自动安装（见 rule_policy.dart）：
  /// 内置规则已覆盖国漫场景；日漫规则留给用户之后在
  /// 设置 → 规则管理 → 规则仓库 里按需手动安装。
  Future<void> _autoSetupAndFinish({required bool openGithub}) async {
    if (autoSetupMessage != null) return;
    setState(() {
      autoSetupMessage = '正在准备初始规则…';
    });

    // 「通过 GitHub 进入」：打开项目仓库页，与「直接进入」等效完成进入。
    if (openGithub) {
      unawaited(_openRepository());
    }

    // 默认同意的一揽子设置。
    await GStorage.putSetting(SettingsKeys.enableBangumiProxy, true);
    await GStorage.putSetting(SettingsKeys.enableGitProxy, true);
    await GStorage.putSetting(SettingsKeys.autoUpdate, true);

    // 免责声明在 v1.6.1 起视为默认同意（statements.txt 仍随包分发可查）。

    var installed = 0;
    var skipped = 0;
    try {
      // 内置规则落盘（原「同意并继续」背后的动作）。
      await pluginsController.copyPluginsToExternalDirectory();

      if (mounted) {
        setState(() => autoSetupMessage = '正在获取规则列表…');
      }
      final catalog = await pluginsController.refreshPluginCatalog();
      // 预过滤：只统计真正会安装的条目，进度提示才不会虚高。
      final installable = <String>[];
      for (final item in catalog) {
        if (shouldSkipAutoInstall(item.name)) {
          skipped++;
        } else {
          installable.add(item.name);
        }
      }
      for (var i = 0; i < installable.length; i++) {
        if (!mounted) return;
        setState(() {
          autoSetupMessage = '正在安装规则 ${i + 1}/${installable.length}…';
        });
        try {
          final result =
              await pluginsController.tryUpdatePluginByName(installable[i]);
          if (result == PluginUpdateResult.updated) installed++;
        } catch (error) {
          // 单条失败不阻断整体流程。
          MiruLogger().w('Plugin: auto install failed for ${installable[i]}',
              error: error);
        }
      }
    } catch (error, stackTrace) {
      MiruLogger()
          .e('Plugin: auto setup failed', error: error, stackTrace: stackTrace);
      if (mounted) {
        MiruDialog.showToast(
            message: '规则自动安装失败，可稍后在 设置 → 规则管理 中重试');
      }
    }

    if (!mounted) return;
    setState(() {
      autoSetupMessage = null;
    });
    if (installed > 0) {
      MiruDialog.showToast(
          message: skipped > 0
              ? '已自动安装 $installed 条规则'
                  '（$skipped 条日漫/失效源可在设置中手动安装）'
              : '已自动安装 $installed 条规则');
    }
    _finish();
  }

  Future<void> _openRepository() async {
    try {
      const url = 'https://github.com/DisenthrallClaude/Miru';
      await launchUrlString(
        url,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      MiruLogger().w('Onboarding: failed to open repository', error: error);
    }
  }

  void _finish({bool replay = false}) {
    // v1.6.3：首次引导完成，落下标志——后续启动不再引导
    //（除非用户在设置里开启「每次启动显示开屏」的重播）。
    if (!replay) {
      unawaited(GStorage.putSetting(SettingsKeys.onboardingDone, true));
    }
    final myController = widget.myController;
    unawaited(runStartupUpdateCheck(
      isEnabled: () => GStorage.getSetting(SettingsKeys.autoUpdate),
      checkForUpdate: () async {
        await myController.checkUpdate(type: 'auto');
      },
    ));
    // v1.6.3：重播是回访用户（已用过 App），公告照常检查；
    // 首启动仍不接——刚装 App 不该被运营内容打扰。
    if (replay) {
      unawaited(AnnouncementService.instance.maybeShowAnnouncement());
    }
    context.navigate(GStorage.getSetting(SettingsKeys.defaultStartupPage));
  }

  /// 退出前弹确认：exit(0) 是不可逆动作，误触不应直接杀进程。
  ///（仅首启动模式；重播模式的返回键直接跳过开屏。）
  void _confirmExit() {
    MiruDialog.show(
      builder: (context) {
        return AlertDialog(
          title: const Text('退出应用'),
          content: const Text('尚未完成初始设置，确定要退出吗？'),
          actions: [
            TextButton(
              onPressed: () {
                MiruDialog.dismiss();
              },
              child: Text(
                '继续设置',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () {
                MiruDialog.dismiss();
                exit(0);
              },
              child: const Text('退出'),
            ),
          ],
        );
      },
    );
  }
}
