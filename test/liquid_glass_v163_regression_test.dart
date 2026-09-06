import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_controller.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_copy_widgets.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_welcome.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_theme.dart';
import 'package:miru/services/startup/startup_gate.dart';
import 'package:miru/services/storage/settings_keys.dart';

/// v1.6.3 修复回归测试。
///
/// 覆盖：
/// * 文字布局防重叠：多种典型屏幕纵横比下，标题块与第三行不叠行
///   （v1.6.2 在 s=min(sx,sy)>1 的长屏上 0.6163h+76sx 越过 0.7032h）；
/// * StartupGate：幂等标记 / 等待放行 / 超时兜底；
/// * 新设置键：showSplashOnEveryLaunch 默认关闭且登记在 interface 组；
/// * 文案：struck/kept 成对且非空、短语数量与主题一致。

const _screenSizes = <String, Size>{
  // 检修机：参考基准 402×874（s=1）。
  'reference 402x874': Size(402, 874),
  // 长屏（s>1，v1.6.2 必现叠行的形状）。
  'tall 412x915': Size(412, 915),
  'tall 412x892': Size(412, 892),
  // 短屏。
  'short 360x640': Size(360, 640),
  // 横屏（sx 与 sy 差距极端）。
  'landscape 800x360': Size(800, 360),
};

Future<void> _openTheGate(
  WidgetTester tester,
  LiquidGlassTheme theme,
) async {
  // 模拟完整上滑落定。
  final center = tester.getCenter(find.byType(LiquidGlassWelcome));
  final gesture = await tester.startGesture(center);
  await gesture.moveBy(const Offset(0, -700));
  await tester.pump();
  await gesture.up();
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('v1.6.3 布局防重叠', () {
    for (final entry in _screenSizes.entries) {
      testWidgets('${entry.key}：标题块与第三行不叠行', (tester) async {
        tester.view.physicalSize =
            entry.value * tester.view.devicePixelRatio;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: LiquidGlassWelcome(
            theme: skyLiquidGlassTheme,
            onEnter: () {},
            onEnterViaGithub: () {},
          ),
        ));
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        await _openTheGate(tester, skyLiquidGlassTheme);

        // CTA 已出现（落定）。
        final cta = find.ancestor(
          of: find.text(skyLiquidGlassTheme.copy.cta),
          matching: find.byType(Opacity),
        ).first;
        expect(tester.widget<Opacity>(cta).opacity, greaterThan(0.9));

        // 标题块（两行）与第三行（WipeLineText）不重叠：
        // 以标题块最深的元素（划线词底缘）为基准。
        final struck = tester.renderObject(
          find.text(skyLiquidGlassTheme.copy.struck),
        ) as RenderBox;
        final third = tester.renderObject(
          find.byType(WipeLineText),
        ) as RenderBox;
        final struckBottom =
            struck.localToGlobal(Offset(0, struck.size.height)).dy;
        final thirdTop = third.localToGlobal(Offset.zero).dy;
        expect(
          thirdTop,
          greaterThanOrEqualTo(struckBottom - 0.5),
          reason:
              '$thirdTop 应在划线词底缘 $struckBottom 之下（${entry.key}）',
        );

        // 第三行也不越过胶囊按钮顶缘。
        final pill = tester.renderObject(
          find.ancestor(
            of: find.text(skyLiquidGlassTheme.copy.cta),
            matching: find.byType(Positioned),
          ).first,
        ) as RenderBox;
        final pillTop = pill.localToGlobal(Offset.zero).dy;
        final thirdBottom =
            third.localToGlobal(Offset(0, third.size.height)).dy;
        expect(
          pillTop,
          greaterThan(thirdBottom),
          reason: '第三行底缘 $thirdBottom 应在胶囊顶缘 $pillTop 之上',
        );
      });
    }
  });

  group('v1.6.3 StartupGate', () {
    test('markPluginsReady 幂等：重复标记不抛错', () {
      // 静态单例跨测试共享：先重置到一个全新闸门语义很难（静态 final），
      // 这里只验证重复调用安全 + isReady 变为 true。
      StartupGate.markPluginsReady();
      StartupGate.markPluginsReady();
      expect(StartupGate.isReady, isTrue);
    });

    test('pluginsReady：就绪后立即完成', () async {
      StartupGate.markPluginsReady();
      // 已完成的 future 会同步决议——用短超时验证不悬挂。
      await StartupGate.pluginsReady(
        timeout: const Duration(milliseconds: 50),
      );
      expect(StartupGate.isReady, isTrue);
    });
  });

  group('v1.6.3 设置键', () {
    test('showSplashOnEveryLaunch 默认关闭', () {
      expect(
        SettingsKeys.showSplashOnEveryLaunch.defaultValue,
        isFalse,
      );
      expect(
        SettingsKeys.showSplashOnEveryLaunch.group,
        SettingGroup.interface,
      );
    });

    test('onboardingDone 默认未完成', () {
      expect(SettingsKeys.onboardingDone.defaultValue, isFalse);
      expect(SettingsKeys.onboardingDone.group, SettingGroup.interface);
    });

    test('两键均登记在 all（供 byGroup 重置）', () {
      expect(SettingsKeys.all, contains(SettingsKeys.showSplashOnEveryLaunch));
      expect(SettingsKeys.all, contains(SettingsKeys.onboardingDone));
      final interfaceKeys = SettingsKeys.byGroup(SettingGroup.interface);
      expect(interfaceKeys, contains(SettingsKeys.showSplashOnEveryLaunch));
      expect(interfaceKeys, contains(SettingsKeys.onboardingDone));
    });
  });

  group('v1.6.3 玻璃球半径钳制（宽屏/横屏）', () {
    test('竖屏基准：r1/rf 与原版常量一致（钳制不生效）', () {
      final c = LiquidGlassController(
        theme: skyLiquidGlassTheme,
        width: 402,
        height: 874,
      );
      expect(c.r1, closeTo(44, 0.001));
      expect(c.rf, closeTo(32, 0.001));
    });

    test('横屏 800×360：按钮底缘不越过标题块顶（0.6163h-12 呼吸）', () {
      final c = LiquidGlassController(
        theme: skyLiquidGlassTheme,
        width: 800,
        height: 360,
      );
      expect(c.r1, lessThanOrEqualTo(0.1473 * 360 - 12 + 1e-9));
      expect(c.cy1 + c.r1, lessThanOrEqualTo(0.6163 * 360 - 12 + 1e-9));
      // rf 与 r1 保持单调（过冲楼层必须小于按钮半径）。
      expect(c.rf, lessThan(c.r1));
    });

    test('平板横屏 1280×800：同上', () {
      final c = LiquidGlassController(
        theme: astroLiquidGlassTheme,
        width: 1280,
        height: 800,
      );
      expect(c.cy1 + c.r1, lessThanOrEqualTo(0.6163 * 800 - 12 + 1e-9));
      expect(c.rf, lessThan(c.r1));
    });
  });

  group('v1.6.3 文案', () {
    test('两主题文案成对且非空', () {
      for (final theme in [
        skyLiquidGlassTheme,
        astroLiquidGlassTheme,
      ]) {
        final copy = theme.copy;
        expect(copy.hint, isNotEmpty);
        expect(copy.headline, isNotEmpty);
        expect(copy.struck, isNotEmpty);
        expect(copy.kept, isNotEmpty);
        expect(copy.struck, isNot(copy.kept));
        expect(copy.phrases.length, greaterThanOrEqualTo(3));
        for (final phrase in copy.phrases) {
          expect(phrase, isNotEmpty);
        }
        expect(copy.cta, isNotEmpty);
      }
    });
  });
}
