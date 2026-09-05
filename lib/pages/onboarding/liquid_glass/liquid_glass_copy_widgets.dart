import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 欢迎屏文案组件 —— 复刻 liquid-glass-screens copy.tsx。
///
/// * [SoftCopyBlock]：原位淡入淡出 + 失焦（blur 随 soften），不动。
/// * [WipeLineText]：第三行 —— 一道从左到右的「对焦前沿」扫过文字，
///   前沿之前已排好但失焦，扫过后变清晰。原文按词分段（字符跨度中点），
///   中文没有空格，这里按字分段以保留扫入效果。

const double _ramp = 0.34; // 失焦前沿宽度（占整行比例）
const double _soft = 26; // 前沿到达前词的失焦量

class SoftCopyBlock extends StatelessWidget {
  const SoftCopyBlock({
    super.key,
    required this.fade,
    required this.soften,
    required this.darkTint,
    required this.child,
    this.shift,
  });

  /// 0..1 透明度。
  final double fade;

  /// 0..~20 失焦量。
  final double soften;

  /// true = 夜间深色 tint。
  final bool darkTint;

  final Widget child;

  /// 与液体同拍的小位移（提示行用）。
  final Offset? shift;

  @override
  Widget build(BuildContext context) {
    final hasBlur = soften > 0.05;
    final tintOpacity = (soften / 2.5).clamp(0.0, 1.0) * 0.10;
    return Opacity(
      opacity: fade,
      child: Transform.translate(
        offset: shift ?? Offset.zero,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (hasBlur)
              Positioned.fill(
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: soften * 0.9,
                      sigmaY: soften * 0.9,
                      tileMode: TileMode.decal,
                    ),
                    child: ColoredBox(
                      color: darkTint
                          ? Colors.black.withValues(alpha: tintOpacity)
                          : Colors.white.withValues(alpha: tintOpacity),
                    ),
                  ),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

/// 第三行：位置对焦扫入。
class WipeLineText extends StatelessWidget {
  const WipeLineText({
    super.key,
    required this.text,
    required this.wipe,
    required this.fade,
    required this.soften,
    required this.darkTint,
    required this.style,
    required this.height,
  });

  final String text;

  /// 0 → 1 对焦前沿位置。
  final double wipe;

  final double fade;
  final double soften;
  final bool darkTint;
  final TextStyle style;
  final double height;

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsOf(text);
    return Opacity(
      opacity: fade,
      child: SizedBox(
        height: height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final seg in segments)
              _WipeSegment(
                segment: seg,
                wipe: wipe,
                soften: soften,
                darkTint: darkTint,
                style: style,
              ),
          ],
        ),
      ),
    );
  }

  static List<_Segment> _segmentsOf(String text) {
    final out = <_Segment>[];
    if (text.contains(' ')) {
      // 拉丁文按词：前导空格跟随词。
      final total = text.length;
      var start = 0;
      final words = text.split(' ');
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        final label = i == 0 ? w : ' $w';
        out.add(_Segment(
          label,
          (start + w.length * 0.5) / total,
        ));
        start += w.length + 1;
      }
    } else {
      // 中文按字（保留扫入效果）。
      final chars = text.characters.toList();
      final total = chars.length;
      for (var i = 0; i < total; i++) {
        out.add(_Segment(chars[i], (i + 0.5) / total));
      }
    }
    return out;
  }
}

class _Segment {
  const _Segment(this.label, this.at);
  final String label;

  /// 段中点在整行中的位置 0..1。
  final double at;
}

class _WipeSegment extends StatelessWidget {
  const _WipeSegment({
    required this.segment,
    required this.wipe,
    required this.soften,
    required this.darkTint,
    required this.style,
  });

  final _Segment segment;
  final double wipe;
  final double soften;
  final bool darkTint;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    // 前沿位置；未到达该段时 t=0（失焦且近乎不可见），过后 t=1（清晰）。
    final front = -_ramp + wipe * (1 + _ramp * 2);
    final t = ((front - segment.at) / _ramp + 0.5).clamp(0.0, 1.0);
    final blur = (1 - t) * _soft + soften;

    final text = Text(
      segment.label,
      style: style,
    );
    if (blur < 0.4) {
      return text;
    }
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: blur * 0.9,
        sigmaY: blur * 0.9,
        tileMode: TileMode.decal,
      ),
      child: Opacity(
        opacity: t,
        child: text,
      ),
    );
  }
}

/// Chrome 气球字标「Miru」——替代原项目的 wordmark 位图。
///
/// 双 pass：白色 keyline 描边 + 纵向 chrome 渐变填充，
/// 夜间配色更冷。绘制在 230×230 的基准框内。
class ChromeWordmark extends StatelessWidget {
  const ChromeWordmark({
    super.key,
    required this.size,
    required this.night,
  });

  final double size;
  final bool night;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ChromeWordmarkPainter(size: size, night: night),
      size: Size.square(size),
    );
  }
}

class _ChromeWordmarkPainter extends CustomPainter {
  _ChromeWordmarkPainter({required this.size, required this.night});

  final double size;
  final bool night;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);

    // 底部柔光（chrome 气球落在玻璃上的那一点亮）。
    final halo = Paint()
      ..shader = RadialGradient(
        colors: [
          (night ? const Color(0xFF9FB4E8) : const Color(0xFFFFFFFF))
              .withValues(alpha: 0.16),
          const Color(0x00000000),
        ],
        radius: 0.6,
      ).createShader(Rect.fromCenter(
        center: center,
        width: canvasSize.width,
        height: canvasSize.height,
      ));
    canvas.drawCircle(center, canvasSize.width * 0.5, halo);

    final fontSize = size * 0.40;
    final span = TextSpan(
      text: 'Miru',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: size * 0.004,
        color: Colors.white,
      ),
    );
    final tp = TextPainter(
      text: span,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();

    final offset = Offset(
      center.dx - tp.width / 2,
      center.dy - tp.height / 2 - size * 0.01,
    );

    // 白色 keyline（外描边）。
    final strokeSpan = TextSpan(
      text: 'Miru',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: size * 0.004,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size * 0.030
          ..strokeJoin = StrokeJoin.round
          ..color = night
              ? const Color(0xFFE9EFFB)
              : const Color(0xFFFFFFFF)
          ..maskFilter = ui.MaskFilter.blur(BlurStyle.normal, size * 0.006),
      ),
    );
    final strokeTp = TextPainter(
      text: strokeSpan,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    strokeTp.paint(
      canvas,
      Offset(
        center.dx - strokeTp.width / 2,
        offset.dy,
      ),
    );

    // chrome 渐变填充。
    // chrome 渐变填充（paint 时 canvas 已平移到文字原点，
    // shader 用局部 (0,0,w,h) 矩形）。
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: night
          ? const [
              Color(0xFFF2F6FF),
              Color(0xFF8EA6E6),
              Color(0xFFDDE8FF),
            ]
          : const [
              Color(0xFFFDFFFE),
              Color(0xFF93AECB),
              Color(0xFFEDF3FA),
            ],
      stops: const [0.0, 0.52, 0.82],
    );
    final fillSpan = TextSpan(
      text: 'Miru',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: size * 0.004,
        foreground: Paint()
          ..shader = gradient.createShader(
            Rect.fromLTWH(0, 0, strokeTp.width, strokeTp.height),
          ),
      ),
    );
    final fillTp = TextPainter(
      text: fillSpan,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    fillTp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChromeWordmarkPainter oldDelegate) =>
      oldDelegate.size != size || oldDelegate.night != night;
}
