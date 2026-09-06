// v1.6.5：开屏特效主题选择（Sky 昼 / Astro 夜）的判定逻辑测试。
//
// 覆盖三条规则及其优先级/边界：
//  1. 北京时间深夜窗口 23:00–06:00（UTC+8 显式换算，不随设备时区漂移）；
//  2. 应用内深色模式（Hive 持久化设置）；
//  3. 系统深色模式（仅「跟随系统」时生效）；
//  以及深夜窗口对浅色设置的强制覆盖（用户需求：23 点后一律黑色版本）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_theme.dart';
import 'package:miru/services/storage/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // mock path_provider，让 GStorage.init 在测试环境可用
  //（与 live_rule_validation_test 同一模式）。
  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        return '/tmp/miru_splash_theme_test';
    }
    return null;
  });

  // 北京 12:00（白天基准）：UTC+8 → UTC 04:00。
  final dayNoonUtc = DateTime.utc(2026, 9, 6, 4, 0);
  // 北京 23:00（深夜窗口起点）：UTC 15:00。
  final nightStartUtc = DateTime.utc(2026, 9, 6, 15, 0);

  group('isBeijingNightWindow 深夜窗口边界', () {
    test('23:00 整点进入深夜', () {
      expect(isBeijingNightWindow(nightStartUtc), isTrue);
    });

    test('次日 02:00 仍在深夜', () {
      // 北京 02:00 = UTC 18:00
      expect(isBeijingNightWindow(DateTime.utc(2026, 9, 6, 18, 0)), isTrue);
    });

    test('05:59 是深夜的最后一分钟', () {
      // 北京 05:59 = UTC 21:59
      expect(isBeijingNightWindow(DateTime.utc(2026, 9, 6, 21, 59)), isTrue);
    });

    test('06:00 整点起回到白天', () {
      // 北京 06:00 = UTC 22:00
      expect(isBeijingNightWindow(DateTime.utc(2026, 9, 6, 22, 0)), isFalse);
    });

    test('12:00 是白天', () {
      expect(isBeijingNightWindow(dayNoonUtc), isFalse);
    });

    test('22:59 是白天（差一分钟入夜）', () {
      // 北京 22:59 = UTC 14:59
      expect(isBeijingNightWindow(DateTime.utc(2026, 9, 6, 14, 59)), isFalse);
    });

    test('跨日边界：1 日 00:30（UTC 前一日 16:30）为深夜', () {
      expect(isBeijingNightWindow(DateTime.utc(2026, 9, 5, 16, 30)), isTrue);
    });
  });

  group('splashEffectiveBrightness 三重判定', () {
    setUpAll(() async {
      Directory('/tmp/miru_splash_theme_test').createSync(recursive: true);
      await Hive.initFlutter('/tmp/miru_splash_theme_test/hive');
      await GStorage.init();
    });

    setUp(() async {
      // 每个用例前复位为「跟随系统」，避免用例间状态泄漏。
      await GStorage.putSetting(SettingsKeys.themeMode, 'system');
    });

    test('跟随系统：白天 + 系统亮 → Sky（亮）', () {
      expect(
        splashEffectiveBrightness(Brightness.light, now: dayNoonUtc),
        Brightness.light,
      );
    });

    test('跟随系统：白天 + 系统暗 → Astro（暗）', () {
      expect(
        splashEffectiveBrightness(Brightness.dark, now: dayNoonUtc),
        Brightness.dark,
      );
    });

    test('应用内深色：即使系统亮、白天也 → Astro（暗）', () async {
      await GStorage.putSetting(SettingsKeys.themeMode, 'dark');
      expect(
        splashEffectiveBrightness(Brightness.light, now: dayNoonUtc),
        Brightness.dark,
      );
    });

    test('应用内浅色：即使系统暗也 → Sky（亮）', () async {
      await GStorage.putSetting(SettingsKeys.themeMode, 'light');
      expect(
        splashEffectiveBrightness(Brightness.dark, now: dayNoonUtc),
        Brightness.light,
      );
    });

    test('深夜窗口强制夜版：即使应用设浅色 + 系统亮', () async {
      await GStorage.putSetting(SettingsKeys.themeMode, 'light');
      expect(
        splashEffectiveBrightness(Brightness.light, now: nightStartUtc),
        Brightness.dark,
      );
    });

    test('深夜窗口强制夜版：应用内深色时同样为暗（叠加不冲突）', () async {
      await GStorage.putSetting(SettingsKeys.themeMode, 'dark');
      expect(
        splashEffectiveBrightness(Brightness.light, now: nightStartUtc),
        Brightness.dark,
      );
    });

    test('深夜窗口强制夜版：跟随系统 + 系统亮（白天系统设置下夜版）', () {
      expect(
        splashEffectiveBrightness(Brightness.light, now: nightStartUtc),
        Brightness.dark,
      );
    });

    test('深夜窗口强制夜版：凌晨 02:00（跨午夜）', () {
      // 北京 02:00 = UTC 18:00
      expect(
        splashEffectiveBrightness(Brightness.light,
            now: DateTime.utc(2026, 9, 6, 18, 0)),
        Brightness.dark,
      );
    });

    test('liquidGlassThemeFor 映射：亮 → Sky、暗 → Astro', () {
      expect(liquidGlassThemeFor(Brightness.light).id, 'sky');
      expect(liquidGlassThemeFor(Brightness.dark).id, 'astro');
      expect(liquidGlassThemeFor(Brightness.light).night, isFalse);
      expect(liquidGlassThemeFor(Brightness.dark).night, isTrue);
    });
  });
}
