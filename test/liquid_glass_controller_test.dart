import 'dart:ui' show Brightness;
import 'package:flutter_test/flutter_test.dart';

import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_controller.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_theme.dart';

/// 液态玻璃欢迎屏控制器（状态机 + 贴纸物理）的移植回归测试。
///
/// 覆盖：行程/半径的几何映射、橡皮筋、弹簧着陆与文案时序、
/// 贴纸羽流发射与两种离场（Sky 坠落 / Astro 漩涡）、槽位安全。
void main() {
  const width = 402.0;
  const height = 874.0;

  LiquidGlassController makeController(LiquidGlassTheme theme) {
    return LiquidGlassController(
      theme: theme,
      width: width,
      height: height,
      reduceMotion: true,
    );
  }

  /// 以 60fps 推进 [seconds] 秒。
  void pump(LiquidGlassController c, double seconds) {
    const frame = Duration(milliseconds: 16);
    final frames = (seconds * 60).round();
    var elapsed = const Duration(milliseconds: 16);
    // 前几帧是 warm-up。
    for (var i = 0; i < frames; i++) {
      c.tick(elapsed);
      elapsed += frame;
    }
  }

  group('geometry', () {
    test('gate 态：穹顶位于底缘，半径 R0', () {
      final c = makeController(skyLiquidGlassTheme);
      expect(c.radius, closeTo(245 * (width / 402), 0.01));
      expect(c.cy, height);
      expect(c.mode, 0);
      expect(c.shown, 0);
    });

    test('按钮态：半径随 p 线性收缩，过冲逼近下限 RF', () {
      final c = makeController(skyLiquidGlassTheme);
      c.p = 1;
      expect(c.radius, closeTo(44 * (width / 402), 0.01));
      c.p = 1.5; // 扔过头：指数逼近 RF=32sx
      final floor = 32 * (width / 402);
      final over = (c.radius - floor) / (44 * (width / 402) - floor);
      expect(over, greaterThan(0));
      expect(over, lessThan(1));
    });

    test('拖到一半松手：带速度的弹簧收敛到 open', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 200,
        translationX: 0,
        translationY: -232, // 一半行程（travel≈464px）
        velocityX: 0,
        velocityY: -3000, // 向上甩
      );
      expect(c.p, closeTo(0.5, 0.01));
      c.onPanEnd(0, -3000);
      pump(c, 2.0);
      expect(c.p, closeTo(1, 0.01));
      expect(c.settled, 1);
      expect(c.mode, 1);
      expect(c.shown, closeTo(1, 0.01));
      expect(c.pillLive, isTrue);
    });

    test('轻推松手：回座 gate', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 700,
        translationX: 0,
        translationY: -100,
        velocityX: 0,
        velocityY: -50,
      );
      c.onPanEnd(0, -50);
      pump(c, 2.0);
      expect(c.p, closeTo(0, 0.01));
      expect(c.settled, 0);
      expect(c.shown, closeTo(0, 0.01));
    });

    test('橡皮筋：两端位移按 25% 计', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 500,
        translationX: 0,
        translationY: 600, // 往下拖出界
        velocityX: 0,
        velocityY: 0,
      );
      expect(c.p, closeTo(-0.323, 0.01)); // 600/464≈1.29 → ×0.25
    });
  });

  group('copy', () {
    test('着陆后文案进入：shown→1，第三行开始轮换', () {
      final c = makeController(skyLiquidGlassTheme);
      // 直接模拟一次成功的上滑释放。
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 200,
        translationX: 0,
        translationY: -900,
        velocityX: 0,
        velocityY: -3000,
      );
      c.onPanEnd(0, -3000);
      pump(c, 1.0);
      expect(c.shown, greaterThan(0.9));
      expect(c.thirdFade, greaterThan(0));
      // 保持 open：短语在 hold(2.51s) 后轮换。
      final before = c.phraseIndex;
      pump(c, 4.0);
      expect(c.phraseIndex, (before + 1) % 4);
    });

    test('gate 文案随行程淡出', () {
      final c = makeController(skyLiquidGlassTheme);
      c.p = 0.35;
      pump(c, 0.1); // 派生量在 tick 中推进
      // 介于 0.08 与 0.62 之间：线性插值。
      expect(c.gateFade, closeTo((0.62 - 0.35) / (0.62 - 0.08), 0.05));
    });
  });

  group('sticker plume', () {
    test('着陆 350ms 后贴纸按序出生', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 200,
        translationX: 0,
        translationY: -900,
        velocityX: 0,
        velocityY: -3000,
      );
      c.onPanEnd(0, -3000);
      pump(c, 0.5); // 着陆 + 0.5s
      var alive = 0;
      for (var i = 0; i < LiquidGlassController.stickerSlots; i++) {
        if (c.state[i * 19 + 5] > 0) alive++;
      }
      expect(alive, greaterThan(0));
      expect(alive, lessThan(LiquidGlassController.stickerSlots));
    });

    test('贴纸稳定漂浮在按钮上方（羽流不坠底）', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 200,
        translationX: 0,
        translationY: -900,
        velocityX: 0,
        velocityY: -3000,
      );
      c.onPanEnd(0, -3000);
      pump(c, 3.0);
      var aliveCount = 0;
      for (var i = 0; i < LiquidGlassController.stickerSlots; i++) {
        final b = i * 19;
        if (c.state[b + 5] <= 0) continue;
        aliveCount++;
        // 羽流区：按钮上方 -600 ~ 附近，不出屏不沉底。
        expect(c.state[b + 1], lessThan(height));
        expect(c.state[b + 1], greaterThan(-150));
        expect(c.state[b], greaterThan(-80));
        expect(c.state[b], lessThan(width + 80));
      }
      expect(aliveCount, greaterThan(30));
    });

    test('状态数组不越界（40 槽 × 19 字段）', () {
      final c = makeController(skyLiquidGlassTheme);
      pump(c, 1.0);
      expect(c.state.length, LiquidGlassController.stickerSlots * 19);
      expect(c.dust.length, 260 * 6);
    });
  });

  group('leaving', () {
    test('Sky：送回 gate 后贴纸坠落并淡出', () {
      final c = makeController(skyLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 200,
        translationX: 0,
        translationY: -900,
        velocityX: 0,
        velocityY: -3000,
      );
      c.onPanEnd(0, -3000);
      pump(c, 1.0);
      expect(c.mode, 1);

      // 送回：从 open 一路拖回 gate。
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 600,
        translationX: 0,
        translationY: 900, // 拖穿整个行程回到 gate 之下
        velocityX: 0,
        velocityY: 300,
      );
      c.onPanEnd(0, 3000);
      pump(c, 3.0);
      expect(c.mode, 0);
      // 全部贴纸死亡或淡出。
      var aliveSum = 0.0;
      for (var i = 0; i < LiquidGlassController.stickerSlots; i++) {
        aliveSum += c.state[i * 19 + 5];
      }
      expect(aliveSum, lessThan(5.0));
    });

    test('Astro：open 释放后进入 vortex 离场', () {
      final c = makeController(astroLiquidGlassTheme);
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 200,
        translationX: 0,
        translationY: -900,
        velocityX: 0,
        velocityY: -3000,
      );
      c.onPanEnd(0, -3000);
      pump(c, 1.2);
      expect(c.mode, 1);

      // astro releaseAt=0.78：往下拖过阈值（tick 内转换模式）。
      c.onPanStart();
      c.onPanUpdate(
        x: 200,
        y: 600,
        translationX: 0,
        translationY: 200, // p≈0.57 < 0.78
        velocityX: 0,
        velocityY: 0,
      );
      pump(c, 0.1);
      expect(c.mode, 2);
      c.onPanEnd(0, 3000);
      pump(c, 2.5);
      // 星尘漩涡吃掉贴纸：alive 大幅减少。
      var aliveCount = 0;
      for (var i = 0; i < LiquidGlassController.stickerSlots; i++) {
        if (c.state[i * 19 + 5] > 0) aliveCount++;
      }
      expect(aliveCount, lessThan(20));
      // feed 光晕在工作后衰减。
      expect(c.feed, greaterThanOrEqualTo(0));
    });
  });

  group('theme', () {
    test('昼夜主题选择', () {
      expect(
        liquidGlassThemeFor(Brightness.light).id,
        'sky',
      );
      expect(
        liquidGlassThemeFor(Brightness.dark).id,
        'astro',
      );
    });
  });
}
