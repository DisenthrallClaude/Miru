import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/settings/theme_provider.dart';
import 'package:miru/bean/settings/settings_detail_scaffold.dart';
import 'package:miru/bean/settings/settings_list.dart';
import 'package:window_manager/window_manager.dart';
import 'package:miru/utils/device.dart';
import 'package:miru/utils/theme.dart';

/// 外观设置页。
///
/// v1.6.4：
/// * 移除「配色方案」与「动态配色」——主题色固定走设计系统默认种子色
///   （页面观感统一，不再提供种子色选择墙）；
/// * 字体链路升级为三级：自定义字体（下载激活）> 系统字体 > 内置
///   思源宋体。「自定义字体」入口进专属字体页（内置精选目录，
///   默认不下载，用户看中哪款下哪款）。
class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  late dynamic defaultDanmakuArea;
  late dynamic defaultThemeMode;
  late bool oledEnhance;
  late bool showWindowButton;
  late bool useSystemFont;
  late final ThemeProvider themeProvider;
  final MenuController menuController = MenuController();

  @override
  void initState() {
    super.initState();
    defaultThemeMode = GStorage.getSetting(SettingsKeys.themeMode);
    oledEnhance = GStorage.getSetting(SettingsKeys.oledEnhance);
    showWindowButton = GStorage.getSetting(SettingsKeys.showWindowButton);
    useSystemFont = GStorage.getSetting(SettingsKeys.useSystemFont);
    themeProvider = context.read<ThemeProvider>();
  }

  void onBackPressed(BuildContext context) {
    if (MiruDialog.observer.hasMiruDialog) {
      MiruDialog.dismiss();
      return;
    }
  }

  /// 主题重建（字体变化后同步 light/dark 两套主题）。
  ///
  /// v1.6.4 起配色方案入口已移除，种子色固定为设计系统默认值；
  /// 本方法只服务字体/OLED 两个维度的主题重建。
  void rebuildThemes() {
    var defaultDarkTheme = buildMiruTheme(
      brightness: Brightness.dark,
      fontFamily: themeProvider.currentFontFamily,
      seedColor: kDefaultSeedColor,
    );
    var oledTheme = oledDarkTheme(defaultDarkTheme);
    themeProvider.setTheme(
      buildMiruTheme(
        brightness: Brightness.light,
        fontFamily: themeProvider.currentFontFamily,
        seedColor: kDefaultSeedColor,
      ),
      oledEnhance ? oledTheme : defaultDarkTheme,
    );
    // 兼容旧数据：themeColor 存量值统一回写为 default，
    // 避免将来读取到不再被 UI 支持的种子色。
    GStorage.putSetting(SettingsKeys.themeColor, 'default');
  }

  void updateTheme(String theme) async {
    if (theme == 'dark') {
      themeProvider.setThemeMode(ThemeMode.dark);
    }
    if (theme == 'light') {
      themeProvider.setThemeMode(ThemeMode.light);
    }
    if (theme == 'system') {
      themeProvider.setThemeMode(ThemeMode.system);
    }
    await GStorage.putSetting(SettingsKeys.themeMode, theme);
    setState(() {
      defaultThemeMode = theme;
    });

    // Update Windows title bar theme
    if (Platform.isWindows) {
      await windowManager.setBrightness(
          themeProvider.isEffectiveDark() ? Brightness.dark : Brightness.light);
    }
  }

  void updateOledEnhance() {
    rebuildThemes();
  }

  /// 字体状态变化后的统一收口：重算 family → 重建主题 → 持久化。
  void _onFontChanged() {
    themeProvider.refreshFontFamily(notify: false);
    rebuildThemes();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        onBackPressed(context);
      },
      child: SettingsDetailScaffold(
        title: const Text('外观设置'),
        body: SettingsList(
          sections: [
            SettingsSection(
              title: Text('外观'),
              tiles: [
                SettingsTile(
                  leading: Icons.dark_mode_rounded,
                  onPressed: (_) {
                    if (menuController.isOpen) {
                      menuController.close();
                    } else {
                      menuController.open();
                    }
                  },
                  title: Text('深色模式'),
                  value: MenuAnchor(
                    consumeOutsideTap: true,
                    controller: menuController,
                    builder: (_, __, ___) {
                      return Text(
                        defaultThemeMode == 'light'
                            ? '浅色'
                            : (defaultThemeMode == 'dark' ? '深色' : '跟随系统'),
                      );
                    },
                    menuChildren: [
                      MenuItemButton(
                        requestFocusOnHover: false,
                        onPressed: () => updateTheme('system'),
                        child: Container(
                          height: 48,
                          constraints: BoxConstraints(minWidth: 112),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.brightness_auto_rounded,
                                  color: defaultThemeMode == 'system'
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '跟随系统',
                                  style: TextStyle(
                                    color: defaultThemeMode == 'system'
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      MenuItemButton(
                        requestFocusOnHover: false,
                        onPressed: () => updateTheme('light'),
                        child: Container(
                          height: 48,
                          constraints: BoxConstraints(minWidth: 112),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.light_mode_rounded,
                                  color: defaultThemeMode == 'light'
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '浅色',
                                  style: TextStyle(
                                      color: defaultThemeMode == 'light'
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : null),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      MenuItemButton(
                        requestFocusOnHover: false,
                        onPressed: () => updateTheme('dark'),
                        child: Container(
                          height: 48,
                          constraints: BoxConstraints(minWidth: 112),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.dark_mode_rounded,
                                  color: defaultThemeMode == 'dark'
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '深色',
                                  style: TextStyle(
                                    color: defaultThemeMode == 'dark'
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                ),
                              ],
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
              title: Text('字体'),
              tiles: [
                SettingsTile(
                  leading: Icons.font_download_rounded,
                  onPressed: (_) async {
                    await context.pushNamed('/settings/theme/fonts');
                  },
                  title: Text('自定义字体'),
                  description: Text('内置精选字体目录 · 按需下载即时生效'),
                  value: Text(themeProvider.currentFontFamily == null
                      ? '系统字体'
                      : '已自定义'),
                ),
                SettingsTile.switchTile(
                  leading: Icons.text_fields_rounded,
                  onToggle: (value) async {
                    useSystemFont = value ?? !useSystemFont;
                    await GStorage.putSetting(
                        SettingsKeys.useSystemFont, useSystemFont);
                    _onFontChanged();
                  },
                  title: Text('使用系统字体'),
                  description: Text('未自定义且开启时使用系统字体，关闭则使用内置思源宋体'),
                  enabled: themeProvider.currentFontFamily == null,
                  initialValue: useSystemFont,
                ),
              ],
              bottomInfo: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '字体优先级：自定义字体 > 系统字体 > 内置思源宋体。'
                  '激活自定义字体后本开关暂不生效，取消自定义字体即恢复。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                ),
              ),
            ),
            SettingsSection(
              title: Text('显示'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.contrast_rounded,
                  onToggle: (value) async {
                    oledEnhance = value ?? !oledEnhance;
                    await GStorage.putSetting(
                        SettingsKeys.oledEnhance, oledEnhance);
                    updateOledEnhance();
                    setState(() {});
                  },
                  title: Text('OLED优化'),
                  description: Text('深色模式下使用纯黑背景'),
                  initialValue: oledEnhance,
                ),
              ],
            ),
            if (isDesktop())
              SettingsSection(
                title: Text('窗口'),
                tiles: [
                  SettingsTile.switchTile(
                    leading: Icons.web_asset_rounded,
                    onToggle: (value) async {
                      showWindowButton = value ?? !showWindowButton;
                      await GStorage.putSetting(
                          SettingsKeys.showWindowButton, showWindowButton);
                      setState(() {});
                    },
                    title: Text('使用系统标题栏'),
                    description: Text('重启应用生效'),
                    initialValue: showWindowButton,
                  ),
                ],
              ),
            if (Platform.isAndroid)
              SettingsSection(
                title: Text('屏幕'),
                tiles: [
                  SettingsTile(
                    leading: Icons.sixty_fps_rounded,
                    onPressed: (_) async {
                      context.pushNamed('/settings/theme/display');
                    },
                    title: Text('屏幕帧率'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
