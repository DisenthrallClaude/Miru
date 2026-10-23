import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/bean/widget/miru_page_transitions.dart';
import 'package:miru/bean/widget/staggered_reveal.dart';
import 'package:miru/pages/player/player_gesture_feedback.dart';
import 'package:miru/pages/video/playback_status_view.dart';
import 'package:miru/utils/haptics.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox(width: 400, height: 240, child: child),
      ),
    );

void main() {
  setUp(() => MiruHaptics.enabled = false);

  group('StaggeredReveal.delayFor', () {
    final epoch = DateTime(2026, 10, 23, 18, 0, 0);
    test('刚出现：按序号错峰', () {
      expect(
        StaggeredReveal.delayFor(index: 0, epoch: epoch, now: epoch),
        Duration.zero,
      );
      expect(
        StaggeredReveal.delayFor(index: 3, epoch: epoch, now: epoch),
        const Duration(milliseconds: 66),
      );
    });
    test('序号超过上限共享最后一档', () {
      expect(
        StaggeredReveal.delayFor(index: 200, epoch: epoch, now: epoch),
        const Duration(milliseconds: 22 * 24),
      );
    });
    test('窗口之后（滚动懒加载）不再入场', () {
      expect(
        StaggeredReveal.delayFor(
          index: 1,
          epoch: epoch,
          now: epoch.add(const Duration(seconds: 2)),
        ),
        isNull,
      );
    });
  });

  group('DoubleTapRippleController', () {
    test('同侧连续双击累加秒数，换侧重置', () {
      final c = DoubleTapRippleController();
      c.trigger(side: 1, seconds: 10);
      c.trigger(side: 1, seconds: 10);
      expect(c.side, 1);
      expect(c.seconds, 20);
      c.trigger(side: -1, seconds: 10);
      expect(c.side, -1);
      expect(c.seconds, 10);
      final serial = c.serial;
      c.clear();
      expect(c.side, 0);
      expect(c.serial, serial);
      c.dispose();
    });
  });

  group('PlaybackLoadingView 文案', () {
    test('阶段标题', () {
      expect(PlaybackLoadingView.titleFor(resolving: true), '正在寻找片源');
      expect(PlaybackLoadingView.titleFor(resolving: false), contains('缓冲'));
    });
    test('久等提示分档', () {
      expect(PlaybackLoadingView.hintFor(2), isNull);
      expect(PlaybackLoadingView.hintFor(9), contains('稍等'));
      expect(PlaybackLoadingView.hintFor(25), contains('换个线路'));
    });
  });

  test('页面过渡时长与纵深参数', () {
    const b = MiruPageTransitionsBuilder();
    expect(b.transitionDuration, const Duration(milliseconds: 420));
    expect(b.reverseTransitionDuration, const Duration(milliseconds: 360));
    expect(b.delegatedTransition, isNotNull);
    expect(MiruPageTransitionsBuilder.recedeScale, lessThan(1));
  });

  testWidgets('加载态可渲染并显示耗时', (tester) async {
    await tester.pumpWidget(_host(const Center(
      child: PlaybackLoadingView(resolving: true),
    )));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('正在寻找片源'), findsOneWidget);
    expect(find.text('解析'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败态：重试与换线路回调', (tester) async {
    var retried = 0;
    var switched = 0;
    await tester.pumpWidget(_host(SingleChildScrollView(
      child: PlaybackErrorView(
        message: '视频解析失败，请重试或切换线路',
        onRetry: () => retried++,
        onSwitchRoad: () => switched++,
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('这一集暂时没能播放'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.tap(find.text('换个线路'));
    expect(retried, 1);
    expect(switched, 1);
  });

  testWidgets('双击涟漪：触发后显示累计秒数并自行收起', (tester) async {
    final c = DoubleTapRippleController();
    await tester.pumpWidget(_host(DoubleTapSeekRipple(controller: c)));
    c.trigger(side: 1, seconds: 10, origin: const Offset(350, 120));
    await tester.pump(const Duration(milliseconds: 100));
    c.trigger(side: 1, seconds: 10, origin: const Offset(350, 120));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('快进 20 秒'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(c.side, 0);
  });

  testWidgets('全屏切换提示：跨过阈值换文案', (tester) async {
    final p = ValueNotifier<double?>(null);
    await tester.pumpWidget(_host(SwipeFullscreenHint(progress: p, exiting: true)));
    p.value = 0.5;
    await tester.pump();
    expect(find.text('下滑退出全屏'), findsOneWidget);
    p.value = 1.1;
    await tester.pump();
    expect(find.text('松手退出全屏'), findsOneWidget);
    p.dispose();
  });

  testWidgets('手势导览渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 420));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GestureCoachOverlay(visible: true),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.text('音量'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
