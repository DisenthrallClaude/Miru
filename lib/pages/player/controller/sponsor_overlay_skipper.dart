import 'dart:async';
import 'dart:typed_data';

import 'package:miru/services/logging/logger.dart';

/// 片头「赞助水印」检测与跳过（v2 去广告）。
///
/// ## 这是什么广告
/// 采集资源站把「本片由 45079.com 赞助发布 / 主营：棋牌 体育 真人娱乐…」
/// 这类文字直接**压制进视频画面**（不是独立的 HLS 分片，也没有
/// DISCONTINUITY），通常叠在片头出品方 logo 的前 10~20 秒。清单级过滤和
/// FFmpeg hls_ad_filter 都对它无能为力——只能从画面识别。
///
/// ## 识别（实测标定）
/// 水印的域名一律是高饱和纯黄色（R、G≥170 且接近，B 很低），横向成行、
/// 纵向很窄，位于画面下部 70%~97% 高度带。用 FQDM 线路的真实片头（0~15s
/// 全部命中、16s 起全部不命中）与 133 秒正片（含夕阳/火光/金色饰品，0 误报）
/// 标定了阈值。另要求**两次采样位置一致**（静态叠字），且只在**从头开播**
/// 时检测——正片中途绝不自动跳。
///
/// ## 跳过
/// 命中后保持遮罩、静音，以 [stepSeconds] 步长向前试探，找到第一个干净
/// 位置后回退二分精修，最后落到干净处起播；[maxSkipSeconds] 内一直有水印
/// （整集常驻型）则放弃、回到 0 秒原样播放，不吞正片。
class OverlayProbe {
  const OverlayProbe({
    required this.hit,
    required this.fraction,
    required this.centerX,
    required this.centerY,
    required this.spanX,
    required this.spanY,
  });

  static const OverlayProbe none = OverlayProbe(
      hit: false, fraction: 0, centerX: 0, centerY: 0, spanX: 0, spanY: 0);

  final bool hit;
  final double fraction;
  final double centerX;
  final double centerY;
  final double spanX;
  final double spanY;

  /// 两次采样是否是同一处静态叠字。
  bool sameOverlayAs(OverlayProbe o) =>
      hit &&
      o.hit &&
      (centerY - o.centerY).abs() <= 0.02 &&
      (centerX - o.centerX).abs() <= 0.05 &&
      fraction / o.fraction >= 0.5 &&
      fraction / o.fraction <= 2.0;

  @override
  String toString() => 'OverlayProbe(hit=$hit frac=${fraction.toStringAsFixed(4)} '
      'c=(${centerX.toStringAsFixed(3)},${centerY.toStringAsFixed(3)}) '
      'span=(${spanX.toStringAsFixed(3)},${spanY.toStringAsFixed(3)}))';
}

abstract final class SponsorOverlayDetector {
  static const double bandTop = 0.70;
  static const double bandBottom = 0.97;
  static const double bandLeft = 0.12;
  static const double bandRight = 0.88;

  static bool isSponsorYellow(int r, int g, int b) =>
      r >= 190 && g >= 170 && b <= 90 && (r - g).abs() <= 45;

  /// [bgra]：mpv screenshot-raw 的 BGRA 像素；[stride] 为每行字节数。
  static OverlayProbe analyze(
    Uint8List bgra, {
    required int width,
    required int height,
    required int stride,
  }) {
    if (width <= 0 || height <= 0 || stride < width * 4) {
      return OverlayProbe.none;
    }
    if (bgra.length < stride * (height - 1) + width * 4) {
      return OverlayProbe.none;
    }
    // 大图降采样：保证每次分析的像素量与分辨率无关（~10 万点）。
    final int step = width >= 1600 ? 4 : (width >= 900 ? 3 : 2);
    final int y0 = (height * bandTop).floor();
    final int y1 = (height * bandBottom).floor();
    final int x0 = (width * bandLeft).floor();
    final int x1 = (width * bandRight).floor();
    final ys = <int>[];
    final xs = <int>[];
    var total = 0;
    for (var y = y0; y < y1; y += step) {
      final row = y * stride;
      for (var x = x0; x < x1; x += step) {
        final i = row + x * 4;
        total++;
        if (isSponsorYellow(bgra[i + 2], bgra[i + 1], bgra[i])) {
          ys.add(y);
          xs.add(x);
        }
      }
    }
    if (total == 0 || ys.length < 5) return OverlayProbe.none;
    final frac = ys.length / total;
    ys.sort();
    xs.sort();
    double pct(List<int> v, double p) => v[((v.length - 1) * p).round()].toDouble();
    final spanY = (pct(ys, 0.9) - pct(ys, 0.1)) / height;
    final spanX = (pct(xs, 0.9) - pct(xs, 0.1)) / width;
    final cy = ys.reduce((a, b) => a + b) / ys.length / height;
    final cx = xs.reduce((a, b) => a + b) / xs.length / width;
    final hit = frac >= 0.0008 && frac <= 0.06 && spanY <= 0.06 && spanX >= 0.06;
    return OverlayProbe(
        hit: hit,
        fraction: frac,
        centerX: cx,
        centerY: cy,
        spanX: spanX,
        spanY: spanY);
  }
}

/// 跳过流程依赖的播放器能力（便于单测注入）。
class SponsorSkipHost {
  SponsorSkipHost({
    required this.probe,
    required this.seek,
    required this.position,
    required this.setMuted,
    required this.isStale,
    this.waitFrameAt,
  });

  /// 取当前画面并分析；拿不到画面返回 null。
  final Future<OverlayProbe?> Function() probe;
  final Future<void> Function(Duration) seek;
  final Duration Function() position;
  final Future<void> Function(bool muted) setMuted;

  /// 换集/退出后为 true，流程立即终止。
  final bool Function() isStale;

  /// seek 之后等到**新位置的画面真正渲染出来**（播放位置在目标附近并向前
  /// 推进）再取帧；超时返回 false。为 null 时退回固定 [SponsorOverlaySkipper.settle]。
  ///
  /// v1.8.0 CI 39947394829 证据：远端 HLS seek 往往要 1~3s 才出新画面，
  /// 固定等 650ms 取到的是 seek 前最后一帧（仍带水印），8 次试探全「脏」→
  /// 误判整集常驻、放弃跳过。
  final Future<bool> Function(Duration target)? waitFrameAt;
}

class SponsorSkipOutcome {
  const SponsorSkipOutcome(this.kind, [this.skippedTo]);
  final String kind; // none | skipped | persistent | aborted
  final Duration? skippedTo;
  @override
  String toString() => 'SponsorSkipOutcome($kind, $skippedTo)';
}

abstract final class SponsorOverlaySkipper {
  static const int stepSeconds = 6;
  static const int maxSkipSeconds = 48;
  static const Duration settle = Duration(milliseconds: 650);

  /// 取帧暂不可用（首帧刚到、VO 尚未出图）时的重试间隔与上限。
  static const Duration grabRetry = Duration(milliseconds: 400);
  static const Duration maxGrabWait = Duration(seconds: 5);

  /// 从头开播、首帧到达后调用。[onActive] 在确认命中后回调 true（UI 遮罩），
  /// 结束时回调 false。
  static Future<SponsorSkipOutcome> run(
    SponsorSkipHost host, {
    void Function(bool active)? onActive,
    Duration firstDelay = const Duration(milliseconds: 350),
    Duration secondDelay = const Duration(milliseconds: 700),
  }) async {
    void log(String m) => MiruLogger().i('MIRU_AD sponsor $m');
    await Future<void>.delayed(firstDelay);
    if (host.isStale()) return const SponsorSkipOutcome('aborted');
    // v1.8.0：首帧回调时 VO 往往还没出图，取帧返回 null（CI 39945352215：
    // 首帧后 350ms `grab failed`，约 2.5s 后 window 取帧成功）。null 表示
    // 「还看不到画面」而不是「没有水印」——重试直到拿到画面或超出等待上限。
    var firstProbe = await host.probe();
    var waited = Duration.zero;
    while (firstProbe == null && waited < maxGrabWait) {
      await Future<void>.delayed(grabRetry);
      waited += grabRetry;
      if (host.isStale()) return const SponsorSkipOutcome('aborted');
      firstProbe = await host.probe();
    }
    final a = firstProbe;
    if (a == null || !a.hit) {
      log('none first=$a');
      return const SponsorSkipOutcome('none');
    }
    await Future<void>.delayed(secondDelay);
    if (host.isStale()) return const SponsorSkipOutcome('aborted');
    final b = await host.probe();
    if (b == null || !a.sameOverlayAs(b)) {
      log('none (not static) a=$a b=$b');
      return const SponsorSkipOutcome('none');
    }
    log('detected a=$a b=$b');
    onActive?.call(true);
    await host.setMuted(true);
    var frameTimeout = false;
    // seek 后迟迟出不了新画面（弱网）：无法判断，回到 0 秒原样播放，
    // 正片中途遮罩仍会兜底盖住水印。
    Future<SponsorSkipOutcome> aborted() async {
      if (frameTimeout && !host.isStale()) {
        await host.seek(Duration.zero);
        log('frame timeout, back to 0');
      }
      return const SponsorSkipOutcome('aborted');
    }

    try {
      Future<bool?> cleanAt(int sec) async {
        await host.seek(Duration(seconds: sec));
        final wait = host.waitFrameAt;
        if (wait != null) {
          if (!await wait(Duration(seconds: sec))) {
            frameTimeout = true;
            return null;
          }
        } else {
          await Future<void>.delayed(settle);
        }
        if (host.isStale()) return null;
        final p = await host.probe();
        if (p == null) return null;
        // 干净 = 没有命中，或命中的已不是同一处叠字。
        return !(p.hit && p.sameOverlayAs(a));
      }

      int? firstClean;
      int lastDirty = 0;
      for (var s = stepSeconds; s <= maxSkipSeconds; s += stepSeconds) {
        final c = await cleanAt(s);
        if (c == null) return await aborted();
        if (c) {
          firstClean = s;
          break;
        }
        lastDirty = s;
      }
      if (firstClean == null) {
        // 整集常驻型：不吞正片，回到开头原样播放。
        await host.seek(Duration.zero);
        log('persistent >${maxSkipSeconds}s, give up');
        return const SponsorSkipOutcome('persistent');
      }
      // 二分精修到 ~1.5s 精度，尽量少跳过出品方 logo。
      var lo = lastDirty, hi = firstClean;
      while (hi - lo > 1) {
        final mid = (lo + hi) ~/ 2;
        final c = await cleanAt(mid);
        if (c == null) return await aborted();
        if (c) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      final target = Duration(seconds: hi);
      if (host.position() < target - const Duration(milliseconds: 500) ||
          host.position() > target + const Duration(seconds: 2)) {
        await host.seek(target);
      }
      log('skipped to ${hi}s');
      return SponsorSkipOutcome('skipped', target);
    } finally {
      await host.setMuted(false);
      onActive?.call(false);
    }
  }
}
