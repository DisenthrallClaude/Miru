import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/sync/bangumi_sync_service.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/sync/webdav.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/settings/settings_detail_scaffold.dart';
import 'package:miru/bean/settings/settings_list.dart';

class WebDavSettingsPage extends StatefulWidget {
  const WebDavSettingsPage({super.key});

  @override
  State<WebDavSettingsPage> createState() => _WebDavSettingsPageState();
}

class _WebDavSettingsPageState extends State<WebDavSettingsPage> {
  late bool webDavEnable;
  late bool webDavEnableHistory;
  late bool webDavEnableCollect;
  late bool enableGitProxy;
  late bool enableBangumiProxy;
  late bool bangumiSyncEnable;

  @override
  void initState() {
    super.initState();
    webDavEnable = GStorage.getSetting(SettingsKeys.webDavEnable);
    webDavEnableHistory = GStorage.getSetting(SettingsKeys.webDavEnableHistory);
    webDavEnableCollect = GStorage.getSetting(SettingsKeys.webDavEnableCollect);
    enableGitProxy = GStorage.getSetting(SettingsKeys.enableGitProxy);
    enableBangumiProxy = GStorage.getSetting(SettingsKeys.enableBangumiProxy);
    bangumiSyncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
  }

  void onBackPressed(BuildContext context) {
    if (MiruDialog.observer.hasMiruDialog) {
      MiruDialog.dismiss();
      return;
    }
  }

  Future<void> syncHistoryWithWebDav() async {
    var webDavEnable = GStorage.getSetting(SettingsKeys.webDavEnable);
    if (webDavEnable) {
      MiruLogger().i('WebDav: manual history sync started');
      MiruDialog.showToast(message: '正在同步观看记录');
      var webDav = WebDav();
      try {
        if (!webDav.isHistorySyncing) {
          await webDav.ping();
        }
        try {
          await webDav.syncHistory();
          MiruLogger().i('WebDav: manual history sync completed');
          MiruDialog.showToast(message: '观看记录同步完成');
        } catch (e) {
          MiruLogger().w('WebDav: manual history sync failed', error: e);
          MiruDialog.showToast(message: '观看记录同步失败 ${e.toString()}');
        }
      } catch (e) {
        MiruLogger().w('WebDav: manual history sync ping failed', error: e);
        MiruDialog.showToast(message: 'WebDav连接失败');
      }
    } else {
      MiruDialog.showToast(message: '未开启WebDav同步或配置无效');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        onBackPressed(context);
      },
      child: SettingsDetailScaffold(
        title: const Text('同步设置'),
        body: SettingsList(
          sections: [
            SettingsSection(
              title: Text('规则仓库'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.hub_rounded,
                  onToggle: (value) async {
                    enableGitProxy = value ?? !enableGitProxy;
                    await GStorage.putSetting(
                        SettingsKeys.enableGitProxy, enableGitProxy);
                    setState(() {});
                  },
                  title: Text('规则仓库镜像'),
                  description: Text('使用镜像访问规则更新和管理仓库'),
                  initialValue: enableGitProxy,
                ),
              ],
            ),
            SettingsSection(
              title: Text('Bangumi'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.cloud_rounded,
                  onToggle: (value) async {
                    enableBangumiProxy = value ?? !enableBangumiProxy;
                    await GStorage.putSetting(
                        SettingsKeys.enableBangumiProxy, enableBangumiProxy);
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  title: Text('Bangumi 镜像'),
                  description: Text(
                      '启用社区镜像加速 Bangumi 数据请求（bgmapi.anibt.net）与封面图代理（wsrv.nl）；需要登录的请求始终直连官方'),
                  initialValue: enableBangumiProxy,
                ),
                SettingsTile.switchTile(
                  leading: Icons.sync_rounded,
                  onToggle: (value) async {
                    final tBangumiEnableSync = value ?? !bangumiSyncEnable;
                    final bangumi = BangumiSyncService();
                    if (tBangumiEnableSync == true) {
                      final token =
                          GStorage.getSetting(SettingsKeys.bangumiAccessToken)
                              .trim();
                      if (token.isEmpty) {
                        MiruDialog.showToast(
                            message: '请先配置 Bangumi 的 Access Token');
                        return;
                      } else {
                        if (!bangumi.initialized) {
                          try {
                            await bangumi.init();
                          } catch (e) {
                            MiruDialog.showToast(
                                message: "Bangumi 初始化失败，请稍后再试");
                            return;
                          }
                        }
                      }
                    }
                    bangumiSyncEnable = tBangumiEnableSync;
                    await GStorage.putSetting(
                        SettingsKeys.bangumiSyncEnable, bangumiSyncEnable);
                    if (!mounted) {
                      return;
                    }
                    setState(() {});
                  },
                  title: Text('Bangumi 同步'),
                  description: Text('允许与Bangumi自动同步收藏/追番状态'),
                  initialValue: bangumiSyncEnable,
                ),
                SettingsTile(
                  leading: Icons.tune_rounded,
                  onPressed: (_) async {
                    await context.pushNamed('/settings/bangumi/');
                    bangumiSyncEnable =
                        GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
                    setState(() {});
                  },
                  title: Text('Bangumi 配置'),
                ),
              ],
            ),
            SettingsSection(
              title: Text('WEBDAV'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.cloud_sync_rounded,
                  onToggle: (value) async {
                    webDavEnable = value ?? !webDavEnable;
                    if (!WebDav().initialized && webDavEnable) {
                      try {
                        await WebDav().init();
                      } catch (e) {
                        webDavEnable = false;
                        MiruDialog.showToast(message: 'WEBDAV初始化失败 $e');
                      }
                    }
                    if (!webDavEnable) {
                      webDavEnableHistory = false;
                      webDavEnableCollect = false;
                      await GStorage.putSetting(
                          SettingsKeys.webDavEnableHistory, false);
                      await GStorage.putSetting(
                          SettingsKeys.webDavEnableCollect, false);
                    }
                    await GStorage.putSetting(
                        SettingsKeys.webDavEnable, webDavEnable);
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  title: Text('WEBDAV同步'),
                  initialValue: webDavEnable,
                ),
                SettingsTile.switchTile(
                  leading: Icons.history_rounded,
                  onToggle: (value) async {
                    if (!webDavEnable) {
                      MiruDialog.showToast(message: '请先开启WEBDAV同步');
                      return;
                    }
                    webDavEnableHistory = value ?? !webDavEnableHistory;
                    await GStorage.putSetting(
                        SettingsKeys.webDavEnableHistory, webDavEnableHistory);
                    setState(() {});
                  },
                  title: Text('观看记录同步'),
                  description: Text('允许自动同步观看记录'),
                  initialValue: webDavEnableHistory,
                ),
                SettingsTile.switchTile(
                  leading: Icons.favorite_rounded,
                  onToggle: (value) async {
                    if (!webDavEnable) {
                      MiruDialog.showToast(message: '请先开启WEBDAV同步');
                      return;
                    }
                    webDavEnableCollect = value ?? !webDavEnableCollect;
                    await GStorage.putSetting(
                        SettingsKeys.webDavEnableCollect, webDavEnableCollect);
                    setState(() {});
                  },
                  title: Text('收藏同步'),
                  description: Text('允许 WebDAV 参与追番状态同步'),
                  initialValue: webDavEnableCollect,
                ),
                SettingsTile(
                  leading: Icons.tune_rounded,
                  onPressed: (_) async {
                    context.pushNamed('/settings/webdav/editor');
                  },
                  title: Text('WEBDAV配置'),
                ),
                SettingsTile(
                  leading: Icons.cloud_upload_rounded,
                  trailing: const Icon(Icons.sync_rounded),
                  onPressed: (_) {
                    syncHistoryWithWebDav();
                  },
                  title: Text('立即同步观看记录'),
                  description: Text('与WEBDAV双向合并观看记录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
