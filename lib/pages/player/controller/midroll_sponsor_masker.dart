import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:miru/pages/player/controller/sponsor_overlay_skipper.dart';
import 'package:miru/services/logging/logger.dart';

/// 正片中途压字广告的毛玻璃遮罩（v1.8.1）。
///
/// ## 这是什么广告
/// 采集站（实测 fcdm 线路 play.modujx10.com，《凡人修仙传》一集 21.5 分钟）
/// 把「582316.com」赌博广告**压制进画面**，整集反复出现，三种固定形态：
/// - [MidrollRegion.center]：中下部两行「本节目由 xx.com 赞助播出 / 主营…」
///   （域名行 y≈0.756），常见于片头片尾字幕段；
/// - [MidrollRegion.top]：顶部横幅——横向滚动跑马灯（y≈0.06）或两行静态
///   块（y≈0.076），实测覆盖 200–400s、860–1020s；
/// - [MidrollRegion.corner]：右下角竖排块「【开元棋牌】xx.com 棋牌 电子 真人
///   注册即送888」（域名行 y≈0.834），实测连续 540–660s。
///
/// 它不是独立分片，清单过滤与跳过都不适用（跳过会吞正片）。
///
/// ## 处理：只在检测到时遮、只遮那一块
/// 每 [interval] 取一帧，按三个固定区域找高饱和纯黄的域名行（与片头水印同一
/// 套颜色判据）。同一区域**连续两次**命中且位置一致（顶部跑马灯只要求纵向
/// 一致）才显示遮罩；**连续两次**不命中撤掉。遮罩只覆盖该形态的文字块，
/// 其余画面一像素不动。实测 74 帧（每 20s 一帧，含太极黄旗、金色雷光、
/// 火光、夕阳）误报 0。
enum MidrollRegion {
  center(0.12, 0.88, 0.70, 0.97, minFrac: 0.0008, maxFrac: 0.06,
      maxSpanY: 0.06, minSpanX: 0.06),
  top(0.0, 1.0, 0.0, 0.14, minFrac: 0.001, maxFrac: 0.08,
      maxSpanY: 0.04, minSpanX: 0.06),
  corner(0.70, 1.0, 0.70, 1.0, minFrac: 0.002, maxFrac: 0.10,
      maxSpanY: 0.045, minSpanX: 0.04);

  const MidrollRegion(this.bandLeft, this.bandRight, this.bandTop, this.bandBottom,
      {required this.minFrac,
      required this.maxFrac,
      required this.maxSpanY,
      required this.minSpanX});

  final double bandLeft;
  final double bandRight;
  final double bandTop;
  final double bandBottom;
  final double minFrac;
  final double maxFrac;
  final double maxSpanY;
  final double minSpanX;

  /// 由域名行的纵向中心推出整块文字的遮罩（归一化到视频画面 0..1）。
  Rect maskFor(OverlayProbe p) {
    final cy = p.centerY;
    final Rect r = switch (this) {
      MidrollRegion.center => Rect.fromLTRB(0.13, cy - 0.045, 0.87, cy + 0.08),
      MidrollRegion.top => Rect.fromLTRB(0.0, cy - 0.045, 1.0, cy + 0.08),
      MidrollRegion.corner => Rect.fromLTRB(0.77, cy - 0.09, 1.0, cy + 0.145),
    };
    return Rect.fromLTRB(
      r.left.clamp(0.0, 1.0),
      r.top.clamp(0.0, 1.0),
      r.right.clamp(0.0, 1.0),
      r.bottom.clamp(0.0, 1.0),
    );
  }

  /// 两次采样是否为同一处压字。顶部跑马灯横向滚动，只比纵向。
  bool consistent(OverlayProbe a, OverlayProbe b) {
    if (!a.hit || !b.hit) return false;
    if ((a.centerY - b.centerY).abs() > 0.015) return false;
    if (this == MidrollRegion.top) return true;
    return (a.centerX - b.centerX).abs() <= 0.05 &&
        a.fraction / b.fraction >= 0.5 &&
        a.fraction / b.fraction <= 2.0;
  }
}

abstract final class MidrollSponsorDetector {
  /// 在 BGRA 帧的 [region] 内找黄色域名行。
  static OverlayProbe analyze(
    Uint8List bgra, {
    required int width,
    required int height,
    required int stride,
    required MidrollRegion region,
  }) {
    if (width <= 0 || height <= 0 || stride < width * 4) {
      return OverlayProbe.none;
    }
    if (bgra.length < stride * (height - 1) + width * 4) {
      return OverlayProbe.none;
    }
    final int step = width >= 1600 ? 4 : (width >= 900 ? 3 : 2);
    final int y0 = (height * region.bandTop).floor();
    final int y1 = (height * region.bandBottom).floor().clamp(0, height);
    final int x0 = (width * region.bandLeft).floor();
    final int x1 = (width * region.bandRight).floor().clamp(0, width);
    final ys = <int>[];
    final xs = <int>[];
    var total = 0;
    for (var y = y0; y < y1; y += step) {
      final row = y * stride;
      for (var x = x0; x < x1; x += step) {
        final i = row + x * 4;
        total++;
        if (SponsorOverlayDetector.isSponsorYellow(
            bgra[i + 2], bgra[i + 1], bgra[i])) {
          ys.add(y);
          xs.add(x);
        }
      }
    }
    if (total == 0 || ys.length < 5) return OverlayProbe.none;
    final frac = ys.length / total;
    ys.sort();
    xs.sort();
    double pct(List<int> v, double p) =>
        v[((v.length - 1) * p).round()].toDouble();
    final spanY = (pct(ys, 0.9) - pct(ys, 0.1)) / height;
    final spanX = (pct(xs, 0.9) - pct(xs, 0.1)) / width;
    final cy = ys.reduce((a, b) => a + b) / ys.length / height;
    final cx = xs.reduce((a, b) => a + b) / xs.length / width;
    final hit = frac >= region.minFrac &&
        frac <= region.maxFrac &&
        spanY <= region.maxSpanY &&
        spanX >= region.minSpanX;
    return OverlayProbe(
        hit: hit,
        fraction: frac,
        centerX: cx,
        centerY: cy,
        spanX: spanX,
        spanY: spanY);
  }

  static Map<MidrollRegion, OverlayProbe> analyzeAll(
    Uint8List bgra, {
    required int width,
    required int height,
    required int stride,
  }) =>
      {
        for (final r in MidrollRegion.values)
          r: analyze(bgra,
              width: width, height: height, stride: stride, region: r),
      };
}

/// 每区域的命中/撤销迟滞状态机（纯逻辑，便于单测）。
class MidrollMaskState {
  final Map<MidrollRegion, OverlayProbe> _last = {};
  final Map<MidrollRegion, int> _misses = {};
  final Map<MidrollRegion, Rect> _active = {};

  /// 当前应显示的遮罩（归一化坐标）。
  List<Rect> get masks => List.unmodifiable(_active.values);

  /// 喂一帧的分析结果，返回遮罩是否有变化。
  bool feed(Map<MidrollRegion, OverlayProbe> probes) {
    var changed = false;
    for (final region in MidrollRegion.values) {
      final p = probes[region] ?? OverlayProbe.none;
      final prev = _last[region];
      if (p.hit) {
        _misses[region] = 0;
        if (_active.containsKey(region)) {
          final next = region.maskFor(p);
          // 跑马灯等轻微抖动不刷新，避免遮罩跳动。
          if ((next.top - _active[region]!.top).abs() > 0.01) {
            _active[region] = next;
            changed = true;
          }
        } else if (prev != null && region.consistent(prev, p)) {
          _active[region] = region.maskFor(p);
          changed = true;
        }
        _last[region] = p;
      } else {
        _last.remove(region);
        if (_active.containsKey(region)) {
          final m = (_misses[region] ?? 0) + 1;
          _misses[region] = m;
          if (m >= 2) {
            _active.remove(region);
            _misses[region] = 0;
            changed = true;
          }
        }
      }
    }
    return changed;
  }

  void reset() {
    _last.clear();
    _misses.clear();
    _active.clear();
  }
}

/// 遮罩循环依赖的播放器能力。
class MidrollMaskHost {
  MidrollMaskHost({
    required this.grab,
    required this.isPlaying,
    required this.isPaused,
    required this.isStale,
    required this.onMasks,
  });

  /// 取一帧并分析三个区域；拿不到画面返回 null。
  final Future<Map<MidrollRegion, OverlayProbe>?> Function() grab;
  final bool Function() isPlaying;

  /// 例如片头跳过流程进行中：本轮不采样。
  final bool Function() isPaused;
  final bool Function() isStale;
  final void Function(List<Rect> masks) onMasks;
}

abstract final class MidrollSponsorMasker {
  static const Duration interval = Duration(milliseconds: 2500);

  static Future<void> run(MidrollMaskHost host,
      {Duration tick = interval}) async {
    final state = MidrollMaskState();
    var loggedOn = <MidrollRegion>{};
    try {
      while (!host.isStale()) {
        await Future<void>.delayed(tick);
        if (host.isStale()) break;
        if (host.isPaused() || !host.isPlaying()) continue;
        Map<MidrollRegion, OverlayProbe>? probes;
        try {
          probes = await host.grab();
        } catch (_) {
          probes = null;
        }
        if (probes == null || host.isStale()) continue;
        if (state.feed(probes)) {
          host.onMasks(state.masks);
          final on = {
            for (final r in MidrollRegion.values)
              if (probes[r]?.hit ?? false) r
          };
          if (on.difference(loggedOn).isNotEmpty) {
            MiruLogger().i('MIRU_AD midroll mask on=${on.map((e) => e.name)}');
          }
          loggedOn = on;
        }
      }
    } finally {
      host.onMasks(const []);
    }
  }
}
