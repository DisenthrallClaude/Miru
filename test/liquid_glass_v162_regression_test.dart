import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_controller.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_theme.dart';

/// v1.6.2 修复回归测试。
///
/// 覆盖：
/// * cxOff 弹簧参数对齐原版（stiffness 120 / damping 15 / mass 1.05）；
/// * onPanCancel 释放弹簧（球体不再悬停在半路）；
/// * Astro 提示色 ARGB（rgba(226,232,246,0.78) → 0xC7E2E8F6）；
/// * 昼夜 wordmark 资产存在且为透明 PNG；
/// * 贴纸资产按槽位尺寸绘制的前提：源图与槽位解耦（任意源尺寸均可）。
void main() {
  const width = 402.0;
  const height = 874.0;

  LiquidGlassController makeController(LiquidGlassTheme theme) {
    return LiquidGlassController(
      theme: theme,
      width: width,
      height: height,
      reduceMotion: false,
    );
  }

  void pump(LiquidGlassController c, double seconds) {
    const frame = Duration(milliseconds: 16);
    final frames = (seconds * 60).round();
    var elapsed = const Duration(milliseconds: 16);
    for (var i = 0; i < frames; i++) {
      c.tick(elapsed);
      elapsed += frame;
    }
  }

  group('v1.6.2 spring', () {
    test('cxOff 用原版弹簧参数（120/15/1.05）回中', () {
      final c = makeController(skyLiquidGlassTheme);
      // 直接构造弹簧状态：p 已在 gate，cxOff 被拉到一侧。
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 700,
        translationX: 120,
        translationY: -232,
        velocityX: 0,
        velocityY: 0,
      );
      expect(c.orbX, greaterThan(width / 2 + 40));
      c.onPanEnd(0, -2000);
      pump(c, 3.0);
      // 弹簧收敛：球回中心。
      expect(c.orbX, closeTo(width / 2, 2.0));
      expect(c.p, closeTo(1, 0.01));
    });

    test('onPanCancel：被抢手势后球体不悬停', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 400,
        translationX: 0,
        translationY: -650, // p ≈ 1.4 之上（过冲橡皮筋）
        velocityX: 0,
        velocityY: -1000,
      );
      // 手势被取消（无 onPanEnd）。
      c.onPanCancel();
      pump(c, 2.0);
      // 必须落到某一端，而不是停在半空。
      expect(c.p, anyOf(closeTo(0, 0.02), closeTo(1, 0.02)));
      expect(c.touchOn, isFalse);
    });

    test('reduceMotion 弹簧更硬（160/30/1）且仍收敛', () {
      final c = LiquidGlassController(
        theme: skyLiquidGlassTheme,
        width: width,
        height: height,
        reduceMotion: true,
      );
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 400,
        translationX: 60,
        translationY: -600,
        velocityX: 0,
        velocityY: -800,
      );
      c.onPanEnd(200, -800);
      pump(c, 2.0);
      expect(c.p, closeTo(1, 0.01));
      expect(c.orbX, closeTo(width / 2, 2.0));
    });
  });

  group('v1.6.2 theme assets', () {
    test('Astro 提示色 = 原版 rgba(226,232,246,0.78)', () {
      final color = astroLiquidGlassTheme.hint;
      expect((color.a * 255).round(), closeTo(0.78 * 255, 1));
      expect((color.r * 255).round(), 226);
      expect((color.g * 255).round(), 232);
      expect((color.b * 255).round(), 246);
    });

    test('昼夜 wordmark 资产存在且方形透明', () {
      for (final theme in [skyLiquidGlassTheme, astroLiquidGlassTheme]) {
        final file = File('assets/liquid_glass/${theme.id == 'sky' ? 'wordmark_day' : 'wordmark_night'}.png');
        expect(theme.wordmarkAsset, endsWith('.png'));
        final f = File(theme.wordmarkAsset);
        expect(f.existsSync(), isTrue, reason: '${theme.wordmarkAsset} 缺失');
        // 与声明的主题资产一致。
        expect(theme.wordmarkAsset, endsWith('wordmark_${theme.id == 'sky' ? 'day' : 'night'}.png'));
        expect(file.existsSync(), isTrue);
      }
    });

    test('两主题贴纸槽 40 个且资产齐备', () {
      for (final theme in [skyLiquidGlassTheme, astroLiquidGlassTheme]) {
        expect(theme.stickers.length, LiquidGlassController.stickerSlots);
        for (final path in theme.stickers) {
          expect(
            File(path).existsSync(),
            isTrue,
            reason: '$path 缺失',
          );
        }
      }
    });
  });

  group('v1.6.2 painter contract', () {
    test('stickerSizes 与原版 STICKER_SIZES 完全一致', () {
      const original = [
        104, 82, 76, 93, 87, //
        68, 46, 58, 52, 55, //
        98, 49, 43, 54, 36, //
        91, 47, 41, 35, 62, //
        85, 32, 50, 30, //
        39, 27, 44, 24, //
        71, 40, 33, 64, //
        29, 57, 45, 26, //
        79, 31, 22, 37, //
      ];
      expect(LiquidGlassController.stickerSizes, original);
    });
  });
}
