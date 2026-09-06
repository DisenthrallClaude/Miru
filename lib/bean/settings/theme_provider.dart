import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:miru/services/fonts/custom_font_service.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/constants.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  bool useDynamicColor = false;
  late ThemeData light;
  late ThemeData dark;
  String? currentFontFamily = customAppFontFamily;

  /// Returns true if the effective theme is dark mode.
  /// Automatically gets platform brightness when themeMode is ThemeMode.system.
  bool isEffectiveDark() {
    if (themeMode == ThemeMode.dark) return true;
    if (themeMode == ThemeMode.light) return false;
    final platformBrightness =
        SchedulerBinding.instance.platformDispatcher.platformBrightness;
    return platformBrightness == Brightness.dark;
  }

  void setTheme(ThemeData light, ThemeData dark, {bool notify = true}) {
    this.light = light;
    this.dark = dark;
    if (notify) notifyListeners();
  }

  void setThemeMode(ThemeMode mode, {bool notify = true}) {
    themeMode = mode;
    if (notify) notifyListeners();
  }

  void setDynamic(bool useDynamicColor, {bool notify = true}) {
    this.useDynamicColor = useDynamicColor;
    if (notify) notifyListeners();
  }

  void setFontFamily(bool useSystemFont, {bool notify = true}) {
    currentFontFamily = useSystemFont ? null : customAppFontFamily;
    if (notify) notifyListeners();
  }

  /// v1.6.4 三级字体来源仲裁：自定义字体（下载并激活的）>
  /// 系统字体（useSystemFont=true）> 内置思源宋体。
  ///
  /// [setFontFamily] 保留为「系统/内置」二态开关的写入入口；
  /// 每次字体状态可能变化（开关切换、自定义字体激活/取消）后
  /// 调用本方法统一重算。自定义字体激活时强制覆盖开关。
  void refreshFontFamily({bool notify = true}) {
    final custom = CustomFontService.instance.activeFamily;
    if (custom != null) {
      currentFontFamily = custom;
    } else if (GStorage.getSetting(SettingsKeys.useSystemFont)) {
      currentFontFamily = null;
    } else {
      currentFontFamily = customAppFontFamily;
    }
    if (notify) notifyListeners();
  }
}
