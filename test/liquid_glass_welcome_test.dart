import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_controller.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_shaders.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_welcome.dart';
import 'package:miru/pages/onboarding/liquid_glass/liquid_glass_theme.dart';

/// 液态玻璃欢迎屏整页冒烟测试：
/// 加载真实资产与 shader，模拟一次完整上滑-落定-回落，
/// 全程不抛异常且状态机走通。
///
/// 注：media_kit 原生库在 flutter_tester 中不可用——_initVideo 的
/// try/catch 会兜底为海报帧，Video 组件不会构建。
void main() {

  Widget host(LiquidGlassTheme theme) => MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: LiquidGlassWelcome(
          theme: theme,
          onEnter: () {},
          onEnterViaGithub: () {},
        ),
      );

  Future<void> pumpPage(
    WidgetTester tester,
    LiquidGlassTheme theme,
  ) async {
    await tester.pumpWidget(host(theme));
    // 资产与 shader 异步加载（页面 ticker 永续，不能 pumpAndSettle）。
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpFor(WidgetTester tester, double seconds) async {
    final frames = (seconds * 60).round();
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// CTA 可见性：pill 常驻树中，以 Opacity 值判定。
  double ctaOpacity(WidgetTester tester, LiquidGlassTheme theme) {
    final op = find
        .ancestor(
          of: find.text(theme.copy.cta),
          matching: find.byType(Opacity),
        )
        .first;
    return tester.widget<Opacity>(op).opacity;
  }

  testWidgets('Astro（夜）：整页渲染 + 上滑落定 + 回落', (tester) async {
    tester.view.physicalSize = const Size(804, 1748); // 2x 402x874
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await pumpPage(tester, astroLiquidGlassTheme);

    // 探测分支：测试环境的透镜路径（记录，两种都允许）。
    // ignore: avoid_print
    print('backdrop lens supported: '
        '${LiquidGlassShaders.isBackdropLensSupported}');

    // gate 态：wordmark 与提示可见。
    expect(find.byType(LiquidGlassWelcome), findsOneWidget);

    // 模拟完整上滑。
    final center = tester.getCenter(find.byType(LiquidGlassWelcome));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, -700));
    await tester.pump();
    await gesture.up();
    await pumpFor(tester, 3.0);

    // 落定后 CTA 出现。
    expect(ctaOpacity(tester, astroLiquidGlassTheme), greaterThan(0.9));
    expect(find.text('通过 GitHub 进入'), findsOneWidget);

    // 回落到 gate。
    final g2 = await tester.startGesture(center);
    await g2.moveBy(const Offset(0, 800));
    await tester.pump();
    await g2.up();
    await pumpFor(tester, 3.0);
    expect(ctaOpacity(tester, astroLiquidGlassTheme), lessThan(0.1));
  });

  testWidgets('Sky（昼）：整页渲染不抛异常（视频缺省走海报兜底）',
      (tester) async {
    tester.view.physicalSize = const Size(804, 1748);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    // path_provider / 视频在测试环境不可用 —— _initVideo 失败兜底海报。
    await pumpPage(tester, skyLiquidGlassTheme);
    expect(find.text(skyLiquidGlassTheme.copy.hint), findsOneWidget);

    // 轻推不落定：文案不出现。
    final center = tester.getCenter(find.byType(LiquidGlassWelcome));
    final g = await tester.startGesture(center);
    await g.moveBy(const Offset(0, -60));
    await tester.pump();
    await g.up();
    await pumpFor(tester, 2.0);
    expect(ctaOpacity(tester, skyLiquidGlassTheme), lessThan(0.1));
  });

  test('liquid glass 主题贴纸槽数恒定', () {
    expect(
      skyLiquidGlassTheme.stickers.length,
      LiquidGlassController.stickerSlots,
    );
    expect(
      astroLiquidGlassTheme.stickers.length,
      LiquidGlassController.stickerSlots,
    );
  });

  testWidgets('真实贴纸绘制：runAsync 加载资产后落定不抛错', (tester) async {
    tester.view.physicalSize = const Size(804, 1748);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(astroLiquidGlassTheme));
    // 真实异步事件循环：让 shader/贴纸/光晕的 rootBundle 解码完成。
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 800),
        ));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 上滑落定 → 贴纸出生（350ms+）→ 涉及色散路径。
    final center = tester.getCenter(find.byType(LiquidGlassWelcome));
    final g = await tester.startGesture(center);
    await g.moveBy(const Offset(0, -700));
    await tester.pump();
    await g.up();
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(ctaOpacity(tester, astroLiquidGlassTheme), greaterThan(0.9));
  });

  test('换词闪帧回归：gap→reveal 转换帧 wipe 归零', () {
    final c = LiquidGlassController(
      theme: astroLiquidGlassTheme,
      width: 402,
      height: 874,
      reduceMotion: true,
    );
    // 直接开到 open 态。
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
    // 推进一整个短语周期到换词边界。
    var lastPhrase = c.phraseIndex;
    var guard = 0;
    while (c.phraseIndex == lastPhrase && guard < 3000) {
      c.tick(Duration(milliseconds: 16 * guard));
      guard++;
      if (c.phraseIndex != lastPhrase) break;
    }
    // 换词发生的那一拍：wipe 必须已经归零（修复前是陈旧的 1）。
    expect(c.wipe, lessThan(0.05));
  });
}
