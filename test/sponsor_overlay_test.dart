import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/player/controller/sponsor_overlay_skipper.dart';

/// 生成 BGRA 画面：背景色 + 可选的一行「赞助黄字」（模拟压制水印）。
Uint8List frame({
  int w = 640,
  int h = 360,
  List<int> bg = const [40, 60, 90], // r,g,b
  bool overlay = false,
  List<int> textRgb = const [235, 215, 20],
  double cy = 0.79,
}) {
  final b = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      b[i] = bg[2];
      b[i + 1] = bg[1];
      b[i + 2] = bg[0];
      b[i + 3] = 255;
    }
  }
  if (overlay) {
    final yc = (h * cy).round();
    for (var y = yc - 5; y <= yc + 5; y++) {
      for (var x = (w * 0.40).round(); x < (w * 0.58).round(); x++) {
        // 笔画：每 3 列 2 列有墨（字形间隙）
        if (x % 3 == 2) continue;
        final i = (y * w + x) * 4;
        b[i] = textRgb[2];
        b[i + 1] = textRgb[1];
        b[i + 2] = textRgb[0];
      }
    }
  }
  return b;
}

OverlayProbe analyze(Uint8List f, {int w = 640, int h = 360}) =>
    SponsorOverlayDetector.analyze(f, width: w, height: h, stride: w * 4);

void main() {
  test('压制黄字水印：命中且两次采样判为同一处', () {
    final a = analyze(frame(overlay: true));
    final b = analyze(frame(overlay: true, bg: const [200, 200, 200]));
    expect(a.hit, isTrue);
    expect(a.centerY, closeTo(0.79, 0.02));
    expect(a.sameOverlayAs(b), isTrue);
  });

  test('无水印 / 大片夕阳橙 / 满屏黄：不命中', () {
    expect(analyze(frame()).hit, isFalse);
    expect(analyze(frame(bg: const [240, 150, 40])).hit, isFalse); // 橙
    expect(analyze(frame(bg: const [235, 215, 20])).hit, isFalse); // 满屏黄
  });

  test('黄字在画面上半部（非水印带）不命中', () {
    expect(analyze(frame(overlay: true, cy: 0.3)).hit, isFalse);
  });

  test('畸形输入安全返回', () {
    expect(analyze(Uint8List(10)).hit, isFalse);
    expect(
        SponsorOverlayDetector.analyze(Uint8List(0),
                width: 0, height: 0, stride: 0)
            .hit,
        isFalse);
  });

  group('SponsorOverlaySkipper', () {
    late Duration pos;
    late bool muted;
    late List<bool> active;
    SponsorSkipHost host(double overlayUntil, {bool stale = false}) {
      final hitProbe = analyze(frame(overlay: true));
      return SponsorSkipHost(
        probe: () async => pos.inMilliseconds / 1000 < overlayUntil
            ? hitProbe
            : OverlayProbe.none,
        seek: (d) async => pos = d,
        position: () => pos,
        setMuted: (m) async => muted = m,
        isStale: () => stale,
      );
    }

    setUp(() {
      pos = Duration.zero;
      muted = false;
      active = [];
    });

    Future<SponsorSkipOutcome> run(SponsorSkipHost h) => SponsorOverlaySkipper.run(
          h,
          onActive: active.add,
          firstDelay: Duration.zero,
          secondDelay: Duration.zero,
        );

    test('片头 15.5s 水印：跳到 16s，期间静音并遮罩，结束恢复', () async {
      final o = await run(host(15.5));
      expect(o.kind, 'skipped');
      expect(o.skippedTo, const Duration(seconds: 16));
      expect(pos, const Duration(seconds: 16));
      expect(muted, isFalse);
      expect(active, [true, false]);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('没有水印：不动', () async {
      final o = await run(host(0));
      expect(o.kind, 'none');
      expect(pos, Duration.zero);
      expect(active, isEmpty);
    });

    test('整集常驻水印：放弃并回到开头，不吞正片', () async {
      final o = await run(host(9999));
      expect(o.kind, 'persistent');
      expect(pos, Duration.zero);
      expect(active, [true, false]);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('换集作废：立即中止', () async {
      final o = await run(host(15, stale: true));
      expect(o.kind, 'aborted');
    });
  });
}
