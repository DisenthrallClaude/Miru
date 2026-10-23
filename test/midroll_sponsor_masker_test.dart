// v1.8.1 正片中途压字广告遮罩：检测阈值、迟滞状态机、显示区域换算。
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/player/controller/midroll_sponsor_masker.dart';
import 'package:miru/pages/player/controller/sponsor_overlay_skipper.dart';
import 'package:miru/pages/player/sponsor_mask_overlay.dart';

const int w = 640, h = 360;

/// 深灰底帧，可在归一化矩形内涂纯黄（模拟域名行）。
Uint8List frame({List<Rect> yellow = const [], List<int> rgb = const [255, 220, 0]}) {
  final b = Uint8List(w * h * 4);
  for (var i = 0; i < b.length; i += 4) {
    b[i] = 40; b[i + 1] = 40; b[i + 2] = 40; b[i + 3] = 255;
  }
  for (final r in yellow) {
    for (var y = (r.top * h).floor(); y < (r.bottom * h).floor(); y++) {
      for (var x = (r.left * w).floor(); x < (r.right * w).floor(); x++) {
        final i = (y * w + x) * 4;
        b[i] = rgb[2]; b[i + 1] = rgb[1]; b[i + 2] = rgb[0];
      }
    }
  }
  return b;
}

Map<MidrollRegion, OverlayProbe> probe(Uint8List f) =>
    MidrollSponsorDetector.analyzeAll(f, width: w, height: h, stride: w * 4);

void main() {
  group('三种实测形态（fcdm 582316.com 坐标）', () {
    test('中下两行：域名行 y≈0.756 → center 命中', () {
      final p = probe(frame(yellow: [const Rect.fromLTRB(0.36, 0.742, 0.50, 0.770)]));
      expect(p[MidrollRegion.center]!.hit, isTrue);
      expect(p[MidrollRegion.top]!.hit, isFalse);
    });
    test('顶部跑马灯 y≈0.06 → top 命中', () {
      final p = probe(frame(yellow: [const Rect.fromLTRB(0.29, 0.045, 0.40, 0.075)]));
      expect(p[MidrollRegion.top]!.hit, isTrue);
    });
    test('右下角块：域名行 y≈0.834 → corner 命中', () {
      final p = probe(frame(yellow: [const Rect.fromLTRB(0.83, 0.82, 0.97, 0.848)]));
      expect(p[MidrollRegion.corner]!.hit, isTrue);
    });
    test('大片黄色（太极旗/金光）纵向跨度过大 → 不命中', () {
      final p = probe(frame(yellow: [const Rect.fromLTRB(0.05, 0.0, 0.6, 1.0)]));
      for (final v in p.values) {
        expect(v.hit, isFalse);
      }
    });
    test('橙色夕阳（G 偏低）不算赞助黄', () {
      final p = probe(frame(
          yellow: [const Rect.fromLTRB(0.36, 0.742, 0.50, 0.770)],
          rgb: const [250, 140, 30]));
      expect(p[MidrollRegion.center]!.hit, isFalse);
    });
  });

  group('迟滞状态机', () {
    final ad = probe(frame(yellow: [const Rect.fromLTRB(0.83, 0.82, 0.97, 0.848)]));
    final clean = probe(frame());

    test('单帧命中不遮；连续两帧一致才遮；连续两帧消失才撤', () {
      final s = MidrollMaskState();
      expect(s.feed(ad), isFalse);
      expect(s.masks, isEmpty);
      expect(s.feed(ad), isTrue);
      expect(s.masks, hasLength(1));
      final m = s.masks.single;
      expect(m.left, closeTo(0.77, 1e-9));
      expect(m.bottom, lessThanOrEqualTo(1.0));
      expect(m.top, lessThan(0.834));
      expect(s.feed(clean), isFalse, reason: '一帧消失仍保持（防闪烁）');
      expect(s.masks, hasLength(1));
      expect(s.feed(clean), isTrue);
      expect(s.masks, isEmpty);
    });

    test('命中—消失—命中（字幕式闪现）不会触发遮罩', () {
      final s = MidrollMaskState();
      s.feed(ad);
      s.feed(clean);
      s.feed(ad);
      expect(s.masks, isEmpty);
    });

    test('顶部跑马灯横向滚动仍判为同一处', () {
      final s = MidrollMaskState();
      s.feed(probe(frame(yellow: [const Rect.fromLTRB(0.10, 0.045, 0.22, 0.075)])));
      s.feed(probe(frame(yellow: [const Rect.fromLTRB(0.70, 0.045, 0.82, 0.075)])));
      expect(s.masks, hasLength(1));
      expect(s.masks.single.left, 0.0);
      expect(s.masks.single.right, 1.0);
    });

    test('中下区域位置跳变（不同字幕行）不遮', () {
      final s = MidrollMaskState();
      s.feed(probe(frame(yellow: [const Rect.fromLTRB(0.20, 0.742, 0.34, 0.770)])));
      s.feed(probe(frame(yellow: [const Rect.fromLTRB(0.60, 0.742, 0.74, 0.770)])));
      expect(s.masks, isEmpty);
    });
  });

  group('显示区域换算', () {
    test('contain：16:9 视频放进 2:1 容器左右留黑，遮罩随视频偏移', () {
      final r = SponsorMaskOverlay.layout(
        [const Rect.fromLTRB(0.0, 0.0, 1.0, 0.5)],
        box: const Size(400, 200),
        video: const Size(1920, 1080),
        fit: BoxFit.contain,
      ).single;
      final vw = 200 * 16 / 9;
      expect(r.left, closeTo((400 - vw) / 2, 0.01));
      expect(r.width, closeTo(vw, 0.01));
      expect(r.height, closeTo(100, 0.01));
    });
    test('cover：裁掉的部分不画遮罩', () {
      final r = SponsorMaskOverlay.layout(
        [const Rect.fromLTRB(0.0, 0.9, 1.0, 1.0)],
        box: const Size(200, 200),
        video: const Size(1920, 1080),
        fit: BoxFit.cover,
      ).single;
      expect(r.left, 0);
      expect(r.right, 200);
      expect(r.bottom, closeTo(200, 0.01));
      expect(r.top, closeTo(180, 0.01));
    });
  });

  test('循环：换集/退出（stale）后清空遮罩', () async {
    var stale = false;
    final seen = <List<Rect>>[];
    var n = 0;
    final ad = probe(frame(yellow: [const Rect.fromLTRB(0.83, 0.82, 0.97, 0.848)]));
    await MidrollSponsorMasker.run(
      MidrollMaskHost(
        grab: () async {
          if (++n >= 3) stale = true;
          return ad;
        },
        isPlaying: () => true,
        isPaused: () => false,
        isStale: () => stale,
        onMasks: seen.add,
      ),
      tick: Duration.zero,
    );
    expect(seen.first, hasLength(1));
    expect(seen.last, isEmpty);
  });
}
