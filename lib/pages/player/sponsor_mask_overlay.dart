import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// v1.8.0：正片中途压字广告的毛玻璃遮罩层。
///
/// [masks] 为归一化到视频画面（0..1）的矩形；按 [fit] 与视频原始尺寸换算到
/// 实际显示区域，只遮那几块。磨砂 + 暮色压暗，即使个别设备 BackdropFilter
/// 采样不到平台纹理，压暗层也足以盖住文字。
class SponsorMaskOverlay extends StatelessWidget {
  const SponsorMaskOverlay({
    super.key,
    required this.masks,
    required this.videoWidth,
    required this.videoHeight,
    required this.fit,
    this.disableAnimations = false,
  });

  final List<Rect> masks;
  final int? videoWidth;
  final int? videoHeight;
  final BoxFit fit;
  final bool disableAnimations;

  /// 把归一化遮罩换算到 [box] 内实际显示的视频区域（纯函数，便于单测）。
  static List<Rect> layout(
    List<Rect> masks, {
    required Size box,
    required Size video,
    required BoxFit fit,
  }) {
    if (masks.isEmpty || video.isEmpty || box.isEmpty) return const [];
    final fitted = applyBoxFit(fit, video, box);
    final dest = Alignment.center.inscribe(fitted.destination, Offset.zero & box);
    // cover 时 source 只是视频的一部分：按 source 在视频中的偏移修正。
    final src = Alignment.center.inscribe(fitted.source, Offset.zero & video);
    final sx = dest.width / src.width;
    final sy = dest.height / src.height;
    final out = <Rect>[];
    for (final m in masks) {
      final r = Rect.fromLTRB(
        dest.left + (m.left * video.width - src.left) * sx,
        dest.top + (m.top * video.height - src.top) * sy,
        dest.left + (m.right * video.width - src.left) * sx,
        dest.top + (m.bottom * video.height - src.top) * sy,
      ).intersect(dest);
      if (r.width > 1 && r.height > 1) out.add(r);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final w = videoWidth, h = videoHeight;
    if (masks.isEmpty || w == null || h == null || w <= 0 || h <= 0) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, constraints) {
        final rects = layout(
          masks,
          box: constraints.biggest,
          video: Size(w.toDouble(), h.toDouble()),
          fit: fit,
        );
        return Stack(
          children: [
            for (final r in rects)
              Positioned.fromRect(
                rect: r,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: disableAnimations
                      ? Duration.zero
                      : const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) =>
                      Opacity(opacity: t, child: child),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                        (r.shortestSide * 0.22).clamp(4.0, 14.0)),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.42),
                              Colors.black.withValues(alpha: 0.55),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.07),
                            width: 0.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}
