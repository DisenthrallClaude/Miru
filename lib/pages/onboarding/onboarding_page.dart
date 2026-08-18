import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/onboarding/steps/disclaimer_step.dart';
import 'package:kazumi/pages/onboarding/steps/mirror_settings_step.dart';
import 'package:kazumi/pages/onboarding/steps/update_source_step.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/update/startup_update_check.dart';

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
  final PageController pageController = PageController();
  int currentIndex = 0;
  bool agreed = false;
  bool installingBundled = false;

  /// 自动配置过程中的进度文案（null 表示未在自动配置）。
  String? autoSetupMessage;
  bool useGithubUpdate = true;

  PluginsController get pluginsController => widget.pluginsController;

  /// 步骤：免责声明 →（Android：更新源）→ 网络镜像。
  /// 「规则订阅」那一步已移除 —— 规则在最后一步完成时自动全量安装。
  int get stepCount => Platform.isAndroid ? 3 : 2;

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  List<Widget> _buildStepBodies() {
    return [
      const DisclaimerStep(),
      if (Platform.isAndroid)
        UpdateSourceStep(
          useGithubUpdate: useGithubUpdate,
          onChanged: (value) {
            GStorage.putSetting(SettingsKeys.autoUpdate, value);
            setState(() {
              useGithubUpdate = value;
            });
          },
        ),
      const MirrorSettingsStep(),
    ];
  }

  String get primaryLabel {
    if (currentIndex == 0 && !agreed) {
      return '同意并继续';
    }
    return currentIndex == stepCount - 1 ? '完成' : '下一步';
  }

  void _goToPage(int index) {
    pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _previousPage() {
    if (currentIndex > 0) {
      _goToPage(currentIndex - 1);
    }
  }

  void _nextPage() {
    if (currentIndex < stepCount - 1) {
      _goToPage(currentIndex + 1);
    } else {
      // 最后一步（网络镜像）完成后，自动安装全部规则再进主界面，
      // 用户无需再逐条点「安装」。
      unawaited(_autoSetupAndFinish());
    }
  }

  Future<void> _agree() async {
    if (agreed) {
      _nextPage();
      return;
    }
    setState(() {
      installingBundled = true;
    });
    try {
      await pluginsController.copyPluginsToExternalDirectory();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'Plugin: failed to install bundled rules',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          installingBundled = false;
        });
      }
      KazumiDialog.showToast(message: '初始化规则失败');
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      agreed = true;
      installingBundled = false;
    });
    _nextPage();
  }

  /// 自动完成：启用网络镜像 → 拉取规则目录 → 逐条安装 → 进入主界面。
  ///
  /// 原流程需要用户在「更新源」「网络镜像」「规则商店」三页里
  /// 反复点下一步并手动逐条点安装，这里一次性做完。
  Future<void> _autoSetupAndFinish() async {
    setState(() {
      autoSetupMessage = '正在启用网络镜像…';
    });
    // 镜像开关默认即为 true，这里显式写入，避免用户此前关闭过
    await GStorage.putSetting(SettingsKeys.enableBangumiProxy, true);
    await GStorage.putSetting(SettingsKeys.enableGitProxy, true);

    var installed = 0;
    try {
      if (mounted) {
        setState(() => autoSetupMessage = '正在获取规则列表…');
      }
      final catalog = await pluginsController.refreshPluginCatalog();
      for (var i = 0; i < catalog.length; i++) {
        if (!mounted) return;
        setState(() {
          autoSetupMessage = '正在安装规则 ${i + 1}/${catalog.length}…';
        });
        try {
          final result =
              await pluginsController.tryUpdatePluginByName(catalog[i].name);
          if (result == PluginUpdateResult.updated) installed++;
        } catch (error) {
          // 单条失败不阻断整体流程
          KazumiLogger().w('Plugin: auto install failed for ${catalog[i].name}',
              error: error);
        }
      }
    } catch (error, stackTrace) {
      KazumiLogger()
          .e('Plugin: auto setup failed', error: error, stackTrace: stackTrace);
      if (mounted) {
        KazumiDialog.showToast(message: '规则自动安装失败，可稍后在 设置 → 规则管理 中重试');
      }
    }

    if (!mounted) return;
    setState(() {
      installingBundled = false;
      autoSetupMessage = null;
    });
    if (installed > 0) {
      KazumiDialog.showToast(message: '已自动安装 $installed 条规则');
    }
    _finish();
  }

  void _handlePrimary() {
    if (currentIndex == 0) {
      unawaited(_agree());
    } else {
      _nextPage();
    }
  }

  void _finish() {
    final myController = widget.myController;
    unawaited(runStartupUpdateCheck(
      isEnabled: () => GStorage.getSetting(SettingsKeys.autoUpdate),
      checkForUpdate: () async {
        await myController.checkUpdate(type: 'auto');
      },
    ));
    context.navigate(GStorage.getSetting(SettingsKeys.defaultStartupPage));
  }

  Widget _buildBottomBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Row(
          children: [
            if (currentIndex == 0)
              TextButton(
                onPressed: () => exit(0),
                child: Text(
                  '退出',
                  style: TextStyle(color: colorScheme.outline),
                ),
              )
            else
              TextButton(
                onPressed: _previousPage,
                child: const Text('上一步'),
              ),
            Expanded(
              child: Center(
                child: autoSetupMessage != null
                    // 自动装规则时把进度显示在这里，让用户知道没有卡死
                    ? Text(
                        autoSetupMessage!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : _PageIndicator(
                        count: stepCount,
                        currentIndex: currentIndex,
                      ),
              ),
            ),
            FilledButton(
              onPressed: (installingBundled || autoSetupMessage != null)
                  ? null
                  : _handlePrimary,
              child: (installingBundled || autoSetupMessage != null)
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(primaryLabel),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        _previousPage();
      },
      child: Scaffold(
        appBar: const SysAppBar(),
        body: Column(
          children: [
            Expanded(
              child: PageView(
                controller: pageController,
                physics: agreed ? null : const NeverScrollableScrollPhysics(),
                onPageChanged: (index) {
                  setState(() {
                    currentIndex = index;
                  });
                },
                children: [
                  for (final body in _buildStepBodies())
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: body,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _buildBottomBar(context),
          ],
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({
    required this.count,
    required this.currentIndex,
  });

  final int count;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == currentIndex ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == currentIndex
                  ? colorScheme.primary
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
