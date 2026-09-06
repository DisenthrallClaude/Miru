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
// expo-blur intensity(0-100) → 近似等效高斯 sigma ≈ 0.35×intensity。
const double _sigmaPerUnit = 0.35;

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

  /// 0..~20 失焦量（原版 BlurView intensity 同尺度）。
  final double soften;

  /// true = 夜间深色 tint。
  final bool darkTint;

  final Widget child;

  /// 与液体同拍的小位移（提示行用）。
  final Offset? shift;

  @override
  Widget build(BuildContext context) {
    // 原版 copy.tsx 的 Soft：内容上盖一层随 soften 增强的失焦幕
    //（BlurView 在 children 之后）。这里直接对内容自身施加高斯模糊
    //（ImageFiltered），叠加原版同款 10% 明暗 tint，视觉等效且不依赖
    // saveLayer 的 backdrop 语义。
    final sigma = soften * _sigmaPerUnit;
    final hasBlur = sigma > 0.05;
    final tintOpacity = (soften / 2.5).clamp(0.0, 1.0) * 0.10;
    Widget content = hasBlur
        ? ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.decal,
            ),
            child: child,
          )
        : child;
    if (hasBlur && tintOpacity > 0.003) {
      content = Stack(
        alignment: Alignment.center,
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: darkTint
                    ? Colors.black.withValues(alpha: tintOpacity)
                    : Colors.white.withValues(alpha: tintOpacity),
              ),
            ),
          ),
        ],
      );
    }
    return Opacity(
      opacity: fade,
      child: Transform.translate(
        offset: shift ?? Offset.zero,
        child: content,
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

    final text = Text(
      segment.label,
      style: style,
    );
    final blur = (1 - t) * _soft * _sigmaPerUnit + soften * _sigmaPerUnit;
    if (blur < 0.15) {
      return Opacity(opacity: t, child: text);
    }
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: blur,
        sigmaY: blur,
        tileMode: TileMode.decal,
      ),
      child: Opacity(
        opacity: t,
        child: text,
      ),
    );
  }
}
