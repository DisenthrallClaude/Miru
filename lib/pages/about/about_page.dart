import 'dart:io';

import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/services/storage/feed_cache.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/utils/device.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({
    super.key,
    required this.controller,
  });

  final MyController controller;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final exitBehaviorTitles = <String>['退出 Miru', '最小化至托盘', '每次都询问'];
  late dynamic defaultDanmakuArea;
  late dynamic defaultThemeMode;
  late dynamic defaultThemeColor;
  late int exitBehavior = GStorage.getSetting(SettingsKeys.exitBehavior);
  late bool autoUpdate;
  late bool checkPluginUpdateOnStartup;
  double _cacheSizeMB = -1;
  MyController get myController => widget.controller;
  final MenuController menuController = MenuController();

  @override
  void initState() {
    super.initState();
    autoUpdate = GStorage.getSetting(SettingsKeys.autoUpdate);
    checkPluginUpdateOnStartup =
        GStorage.getSetting(SettingsKeys.checkPluginUpdateOnStartup);
    _getCacheSize();
  }

  void onBackPressed(BuildContext context) {
    if (KazumiDialog.observer.hasKazumiDialog) {
      KazumiDialog.dismiss();
      return;
    }
  }

  Future<Directory> _getCacheDir() async {
    Directory tempDir = await getTemporaryDirectory();
    return Directory('${tempDir.path}/libCachedImageData');
  }

  Future<void> _getCacheSize() async {
    Directory cacheDir = await _getCacheDir();

    if (await cacheDir.exists()) {
      int totalSizeBytes = await _getTotalSizeOfFilesInDir(cacheDir);
      double totalSizeMB = (totalSizeBytes / (1024 * 1024));

      if (mounted) {
        setState(() {
          _cacheSizeMB = totalSizeMB;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _cacheSizeMB = 0.0;
        });
      }
    }
  }

  Future<int> _getTotalSizeOfFilesInDir(final Directory directory) async {
    final List<FileSystemEntity> children = directory.listSync();
    int total = 0;

    try {
      for (final FileSystemEntity child in children) {
        if (child is File) {
          final int length = await child.length();
          total += length;
        } else if (child is Directory) {
          total += await _getTotalSizeOfFilesInDir(child);
        }
      }
    } catch (_) {}
    return total;
  }

  Future<void> _clearCache() async {
    final Directory libCacheDir = await _getCacheDir();
    if (await libCacheDir.exists()) {
      await libCacheDir.delete(recursive: true);
    }
    await FeedCache.clear();
    _getCacheSize();
  }

  /// 反馈弹窗。风格与项目一致：走 KazumiDialog（自带玻璃背景模糊），
  /// 主动作用强调色、次要动作用次级灰。
  void _showFeedbackDialog() {
    KazumiDialog.show(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('意见反馈'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('遇到 bug 或有功能建议，欢迎邮件联系。'
                  '本项目仍在完善中，反馈时请尽量附上复现步骤。'),
              const SizedBox(height: 16),
              SelectableText(
                ApiEndpoints.feedbackEmail,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: KazumiDialog.dismiss,
              child: Text(
                '关闭',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () async {
                final uri = Uri(
                  scheme: 'mailto',
                  path: ApiEndpoints.feedbackEmail,
                  queryParameters: const {'subject': 'Miru 反馈'},
                );
                KazumiDialog.dismiss();
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (_) {
                  KazumiDialog.showToast(message: '未找到邮件应用，可手动复制邮箱地址');
                }
              },
              child: Text(
                '发送邮件',
                style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showCacheDialog() {
    KazumiDialog.show(
      builder: (context) {
        return AlertDialog(
          title: const Text('缓存管理'),
          content: const Text(
              '将清除番剧封面缓存，以及推荐页 / 时间表的本地列表。下次进入对应页面会重新联网。'),
          actions: [
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
              },
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () async {
                try {
                  _clearCache();
                } catch (_) {}
                KazumiDialog.dismiss();
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        onBackPressed(context);
      },
      child: SettingsDetailScaffold(
        title: const Text('关于'),
        body: SettingsList(
          sections: [
            SettingsSection(
              title: Text('关于本项目'),
              bottomInfo: Text(
                'Miru 基于开源项目 Kazumi 修改而来，主要改了两件事：\n'
                '· 面向国漫用户优化 —— 推荐与时间表只出国漫，'
                '并接入无需密钥的公共反代，解决国内直连不通的问题；\n'
                '· 面向观感与交互重做 UI —— 衬线排印、液态玻璃材质、'
                '仿主流视频站的首页版式。\n\n'
                '需要说明：本项目仍有大量 bug 与待优化之处，'
                '并非成熟产品，请酌情使用。\n'
                '原项目版权归原作者所有，遵循其开源许可证发布；'
                '本修改版同样开源，不用于商业用途。',
              ),
              tiles: [
                SettingsTile(
                  leading: Icons.code_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.sourceUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('本项目仓库'),
                  description: Text('DisenthrallClaude/Miru'),
                ),
                SettingsTile(
                  leading: Icons.source_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.upstreamSourceUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('原项目仓库'),
                  description: Text('Predidit/Kazumi · 上游源码'),
                ),
                SettingsTile(
                  leading: Icons.gavel_rounded,
                  onPressed: (_) {
                    context.pushNamed('/settings/about/license');
                  },
                  title: Text('开源许可证'),
                  description: Text('查看所有开源许可证'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('致谢'),
              tiles: [
                SettingsTile(
                  leading: Icons.bug_report_rounded,
                  title: Text('内测用户'),
                  description: Text('@灯塔上的雾'),
                ),
                SettingsTile(
                  leading: Icons.favorite_rounded,
                  title: Text('赞助商'),
                  description: Text('@小圆猪'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('反馈'),
              tiles: [
                SettingsTile(
                  leading: Icons.mail_rounded,
                  onPressed: (_) => _showFeedbackDialog(),
                  title: Text('意见反馈'),
                  description: Text('遇到问题或有建议，欢迎邮件联系'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('外部链接'),
              tiles: [
                SettingsTile(
                  leading: Icons.home_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.projectUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('项目主页'),
                ),
                SettingsTile(
                  leading: Icons.code_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.sourceUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('代码仓库'),
                  value: Text('Github'),
                ),
                SettingsTile(
                  leading: Icons.brush_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.iconUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('图标创作'),
                  value: Text('Pixiv'),
                ),
                SettingsTile(
                  leading: Icons.menu_book_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.bangumiIndex),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('番剧索引'),
                  value: Text('Bangumi'),
                ),
                SettingsTile(
                  leading: Icons.image_search_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse('https://trace.moe'),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('以图搜番'),
                  value: Text('trace.moe'),
                ),
                SettingsTile(
                  leading: Icons.subtitles_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.dandanIndex),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('弹幕来源'),
                  description: Text('ID: ${dandanCredentials['id']}'),
                  value: Text('弹弹play开放平台'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('社区'),
              tiles: [
                SettingsTile(
                  leading: Icons.send_rounded,
                  onPressed: (_) {
                    launchUrl(Uri.parse(ApiEndpoints.telegramGroup),
                        mode: LaunchMode.externalApplication);
                  },
                  title: Text('Telegram'),
                  value: Text('点击加入'),
                ),
              ],
            ),
            if (isDesktop()) // 之后如果有非桌面平台的新选项可以移除
              SettingsSection(
                title: Text('默认行为'),
                tiles: [
                  SettingsTile(
                    leading: Icons.exit_to_app_rounded,
                    onPressed: (_) {
                      if (menuController.isOpen) {
                        menuController.close();
                      } else {
                        menuController.open();
                      }
                    },
                    title: Text('关闭时'),
                    value: MenuAnchor(
                      consumeOutsideTap: true,
                      controller: menuController,
                      builder: (_, __, ___) {
                        return Text(exitBehaviorTitles[exitBehavior]);
                      },
                      menuChildren: [
                        for (int i = 0; i < 3; i++)
                          MenuItemButton(
                            requestFocusOnHover: false,
                            onPressed: () {
                              exitBehavior = i;
                              GStorage.putSetting(SettingsKeys.exitBehavior, i);
                              setState(() {});
                            },
                            child: Container(
                              height: 48,
                              constraints: BoxConstraints(minWidth: 112),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  exitBehaviorTitles[i],
                                  style: TextStyle(
                                    color: i == exitBehavior
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            SettingsSection(
              title: Text('存储与日志'),
              tiles: [
                SettingsTile(
                  leading: Icons.receipt_long_rounded,
                  onPressed: (_) {
                    context.pushNamed('/settings/about/logs');
                  },
                  title: Text('错误日志'),
                ),
                SettingsTile(
                  leading: Icons.cleaning_services_rounded,
                  onPressed: (_) {
                    _showCacheDialog();
                  },
                  title: Text('清除缓存'),
                  value: _cacheSizeMB == -1
                      ? Text('统计中...')
                      : Text('${_cacheSizeMB.toStringAsFixed(2)}MB'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('应用更新'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.update_rounded,
                  onToggle: (value) async {
                    autoUpdate = value ?? !autoUpdate;
                    await GStorage.putSetting(
                        SettingsKeys.autoUpdate, autoUpdate);
                    setState(() {});
                  },
                  title: Text('启动时检查应用更新'),
                  initialValue: autoUpdate,
                ),
                SettingsTile(
                  leading: Icons.system_update_rounded,
                  onPressed: (_) {
                    myController.checkUpdate();
                  },
                  title: Text('检查应用更新'),
                  value: Text('当前版本 ${ApiEndpoints.version}'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('规则更新'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.extension_rounded,
                  onToggle: (value) async {
                    checkPluginUpdateOnStartup =
                        value ?? !checkPluginUpdateOnStartup;
                    await GStorage.putSetting(
                      SettingsKeys.checkPluginUpdateOnStartup,
                      checkPluginUpdateOnStartup,
                    );
                    setState(() {});
                  },
                  title: Text('启动时检查规则更新'),
                  initialValue: checkPluginUpdateOnStartup,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
