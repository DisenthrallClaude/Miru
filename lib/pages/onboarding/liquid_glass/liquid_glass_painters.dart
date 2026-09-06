import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'liquid_glass_controller.dart';
import 'liquid_glass_shaders.dart';
import 'liquid_glass_theme.dart';

/// 玻璃球（穹顶 / + 按钮）画笔 —— 直接驱动 glass.frag。
///
/// uniform 全部换算到物理像素（FlutterFragCoord 即物理像素空间）。
class GlassSpherePainter extends CustomPainter {
  GlassSpherePainter({
    required this.controller,
    required this.theme,
    required this.dpr,
  });

  final LiquidGlassController controller;
  final LiquidGlassTheme theme;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    // 复用单例实例：每帧新建 FragmentShader 是纯分配浪费。
    final shader = LiquidGlassShaders.glass();
    final R = controller.radius;
    final orbX = controller.orbX;
    final cy = controller.cy;
    if (R <= 0) return;

    if (shader == null) {
      // 降级：无 shader（如极端后端异常）时画一个多层玻璃近似，
      // 而不是 v1.6.2 的单个半透明白圆——那正是「不通透、无光影」
      // 观感的来源之一。层次复刻 glass.frg 的静态部分：
      // 外光晕 → 乳白体 → 发丝缘光 → 左上 sheen。
      _paintFallbackOrb(canvas, Offset(orbX, cy), R, theme.night);
      return;
    }

    // dv：单位化。
    final n = math.max(1e-4, math.sqrt(controller.dirX * controller.dirX +
        controller.dirY * controller.dirY));

    final small = _clamp01(
        _lerpRange(R, controller.r1 * 1.05, controller.r1 * 1.7, 1, 0));
    final caus = _clamp01(
        _lerpRange(R, 100 * controller.sx, 190 * controller.sx, 0, 1));

    shader.setFloat(0, orbX * dpr);
    shader.setFloat(1, cy * dpr);
    shader.setFloat(2, R * dpr);
    shader.setFloat(3, controller.glow);
    shader.setFloat(4, controller.dirX / n);
    shader.setFloat(5, controller.dirY / n);
    shader.setFloat(6, small);
    shader.setFloat(7, caus);
    shader.setFloat(8, theme.night ? 1 : 0);

    final paint = Paint()..shader = shader;
    // 覆盖 halo 外缘（1.34R 见 shader）。
    final box = R * 1.36;
    final rect = Rect.fromCenter(
      center: Offset(orbX, cy),
      width: box * 2,
      height: box * 2,
    );
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant GlassSpherePainter oldDelegate) => true;

  /// 降级玻璃球（无 shader 路径）：用径向渐变分层模拟 glass.frg。
  void _paintFallbackOrb(Canvas canvas, Offset c, double R, bool night) {
    // ── 外光晕（halo）──
    // 白天：柔和灰影、下方更重；夜晚：蓝白光晕、顶部更亮。
    final haloPaint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, R * 0.10);
    if (night) {
      haloPaint.shader = ui.Gradient.radial(
        c,
        R * 1.22,
        [
          const ui.Color(0x338CB8FF),
          const ui.Color(0x00081020),
        ],
      );
    } else {
      haloPaint.shader = ui.Gradient.radial(
        c,
        R * 1.16,
        [
          const ui.Color(0x24000000),
          const ui.Color(0x00000000),
        ],
      );
    }
    canvas.drawCircle(c, R * 1.22, haloPaint);

    // ── 乳白体（body）：中心更亮、边缘渐薄 ──
    final bodyAlpha = night ? 0.07 : 0.13;
    final bodyPaint = Paint()
      ..shader = ui.Gradient.radial(
        c,
        R,
        [
          ui.Color.fromARGB((bodyAlpha * 255 * 1.35).round().clamp(0, 255),
              255, 255, 255),
          ui.Color.fromARGB((bodyAlpha * 255 * 0.55).round().clamp(0, 255),
              255, 255, 255),
        ],
      );
    canvas.drawCircle(c, R, bodyPaint);

    // ── 发丝缘光（rim hairline）──
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, R * 0.012)
      ..color = night
          ? const ui.Color(0x99D8E4FF)
          : const ui.Color(0xB3FFFFFF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8);
    canvas.drawCircle(c, R * 0.985, rimPaint);

    // ── 右上 sheen：一段亮弧（峰值 ~1 点钟，对齐 glass.frg 的
    // up = normalize(0.30, -0.95)）+ 一片内侧漫射。v1.6.3 修正了
    // 首版左右镜像的错误（sweep 顺时针从 3 点钟起算：1 点钟 = 300°
    // = stop 0.833）。──
    final sheenRect = Rect.fromCircle(center: c, radius: R);
    final sheenSweep = ui.Gradient.sweep(
      c,
      [
        const ui.Color(0x00FFFFFF),
        const ui.Color(0x66FFFFFF),
        const ui.Color(0x00FFFFFF),
      ],
      const [0.58, 0.833, 0.97],
      TileMode.clamp,
    );
    final sheenPaint = Paint()
      ..shader = sheenSweep
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, R * 0.03);
    final rimBand = Path()
      ..addOval(Rect.fromCircle(center: c, radius: R * 0.96))
      ..addOval(Rect.fromCircle(center: c, radius: R * 0.78))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(rimBand, sheenPaint);

    // 内侧右上漫射高光（1 点钟方向，同 sheen 峰值）。
    final innerPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(c.dx + R * 0.30, c.dy - R * 0.32),
        R * 0.75,
        [
          const ui.Color(0x2EFFFFFF),
          const ui.Color(0x00FFFFFF),
        ],
      );
    canvas.drawOval(sheenRect, innerPaint);
  }
}

/// 贴纸场画笔 —— 40 贴纸 + 星尘（vortex）。
///
/// 贴纸变换序（与 RN 版 transform 数组语义一致）：
/// translate → rotate(heading) → scale(1+0.9st, 1-0.42st) →
/// rotate(-heading) → scale(scale) → rotate(rot)。
///
/// 绘制尺寸 = 槽位尺寸（STICKER_SIZES，pt），源 PNG 以 drawImageRect
/// 压入目标矩形 —— 与原版 `Image fit="contain" width={size} height={size}`
/// 完全一致（源图 512×512，直接 drawImage 会把贴纸画成 5 倍大）。
///
/// [approxLens] 为 true（无 Impeller 的回退路径）时，贴纸经过按钮附近
/// 用手工放大+色散近似透镜；真实 backdrop 透镜路径下透镜本身会折射，
/// 这里不再叠加。
class StickerFieldPainter extends CustomPainter {
  StickerFieldPainter({
    required this.controller,
    required this.theme,
    required this.images,
    this.approxLens = false,
    this.repaint,
  });

  final LiquidGlassController controller;
  final LiquidGlassTheme theme;
  final List<ui.Image?> images;

  /// 回退路径：无真实 backdrop 透镜时启用近似放大。
  final bool approxLens;
  final Listenable? repaint;

  @override
  void paint(Canvas canvas, Size size) {
    final s = controller.state;
    final R = controller.radius;
    final orbX = controller.orbX;
    final cy = controller.cy;
    final slots = LiquidGlassController.stickerSlots;
    const k = 19;

    // ── 星尘（vortex）——两层深度：新尘亮而近，旧尘淡而远 ──
    if (theme.isVortex) {
      final d = controller.dust;
      const motes = 260;
      const dk = 6;
      final bright = <ui.Offset>[];
      final dim = <ui.Offset>[];
      for (var q = 0; q < motes; q++) {
        final c = q * dk;
        final life = d[c + 4];
        if (life <= 0) continue;
        final point = ui.Offset(d[c], d[c + 1]);
        if (life > d[c + 5] * 0.55) {
          bright.add(point);
        } else {
          dim.add(point);
        }
      }
      if (dim.isNotEmpty) {
        // 原版：rgba(150, 200, 255, 0.38)。
        final paint = Paint()
          ..color = const Color(0x6196C8FF)
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        canvas.drawPoints(ui.PointMode.points, dim, paint);
      }
      if (bright.isNotEmpty) {
        final paint = Paint()
          ..color = const Color(0xEBE1F2FF)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        canvas.drawPoints(ui.PointMode.points, bright, paint);
      }
    }

    // ── 贴纸 ──
    final disp = R < controller.r1 * 1.8
        ? theme.buttonDispersion
        : theme.domeDispersion;

    for (var i = 0; i < slots; i++) {
      final b = i * k;
      final alive = s[b + 5];
      if (alive <= 0) continue;
      // 贴纸图异步解码完成前列表可能为空/不齐 —— 越界会让整层绘制
      // 抛 RangeError（v1.6.1 的实际线上 bug：层被废掉直到下一帧重建）。
      final img = i < images.length ? images[i] : null;
      if (img == null) continue;

      final x = s[b];
      final y = s[b + 1];
      final scale = math.max(0.001, s[b + 4]);
      final heading = s[b + 11];
      final stretch = s[b + 12];
      final rot = s[b + 9];
      final slotSize = LiquidGlassController.stickerSizes[i];
      final half = slotSize / 2;
      final src = ui.Rect.fromLTWH(
          0, 0, img.width.toDouble(), img.height.toDouble());
      final dst = ui.Rect.fromLTWH(-half, -half, slotSize, slotSize);

      // 回退路径的球内放大（出生透过按钮玻璃的折射近似）。
      var mag = 1.0;
      var chroma = 0.0;
      if (approxLens) {
        final dx = x - orbX;
        final dy = y - cy;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (R < controller.r1 * 1.8 && R > 1 && dist < R * 1.02) {
          final rr = dist / R;
          mag = 1 + 0.9 * (1 - rr);
          chroma = disp * (1 - rr) * 0.22;
        }
      }

      final op = (alive * 255).round().clamp(0, 255);

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(heading);
      canvas.scale(1 + stretch * 0.9, 1 - stretch * 0.42);
      canvas.rotate(-heading);
      canvas.scale(scale * mag, scale * mag);
      canvas.rotate(rot);

      if (chroma > 0.002) {
        // RGB 三层色散（plus 混合，提取单通道）。
        // ColorFilter.matrix 必须是 4×5=20 元素；alpha 行保留 A
        // 以维持贴纸镂空形状。
        _drawChannel(canvas, img, src, dst, op, chroma, const [
          1, 0, 0, 0, 0, // R' = R
          0, 0, 0, 0, 0, // G' = 0
          0, 0, 0, 0, 0, // B' = 0
          0, 0, 0, 1, 0, // A' = A
        ]);
        _drawChannel(canvas, img, src, dst, op, 0, const [
          0, 0, 0, 0, 0, // R' = 0
          0, 1, 0, 0, 0, // G' = G
          0, 0, 0, 0, 0, // B' = 0
          0, 0, 0, 1, 0, // A' = A
        ]);
        _drawChannel(canvas, img, src, dst, op, -chroma, const [
          0, 0, 0, 0, 0, // R' = 0
          0, 0, 0, 0, 0, // G' = 0
          0, 0, 1, 0, 0, // B' = B
          0, 0, 0, 1, 0, // A' = A
        ]);
      } else {
        final paint = Paint()
          ..color = Color.fromARGB(255, 255, 255, 255)
          ..filterQuality = FilterQuality.medium;
        if (op < 255) {
          paint.color = Color.fromARGB(op, 255, 255, 255);
        }
        canvas.drawImageRect(img, src, dst, paint);
      }
      canvas.restore();
    }
  }

  void _drawChannel(
    Canvas canvas,
    ui.Image img,
    ui.Rect src,
    ui.Rect dst,
    int op,
    double offset,
    List<double> matrix,
  ) {
    canvas.save();
    canvas.translate(offset * dst.width * 0.3, -offset * dst.width * 0.075);
    final paint = Paint()
      ..color = Color.fromARGB(op, 255, 255, 255)
      ..colorFilter = ColorFilter.matrix(matrix)
      ..blendMode = BlendMode.plus
      ..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(img, src, dst, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant StickerFieldPainter oldDelegate) => true;
}

/// 透镜画笔（Astro）：用预捕获的星空图做真实 backdrop 折射。
class LensPainter extends CustomPainter {
  LensPainter({
    required this.controller,
    required this.theme,
    required this.scene,
    required this.dpr,
  });

  final LiquidGlassController controller;
  final LiquidGlassTheme theme;
  final ui.Image? scene;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final img = scene;
    if (img == null) return;
    // 单例复用：每帧重设 sampler 与 uniform。
    final shader = LiquidGlassShaders.lens();
    if (shader == null) return;

    final R = controller.radius;
    final orbX = controller.orbX;
    final cy = controller.cy;

    final amount = _clamp01(
        _lerpRange(R, controller.r1, controller.r0, 0.62, 0.42));
    final bezel = _clamp01(
        _lerpRange(R, controller.r1, controller.r0, 0.42, 0.25));
    final disp = _clamp01(_lerpRange(
        R,
        controller.r1,
        controller.r0 * theme.domeAt,
        theme.buttonDispersion,
        theme.domeDispersion));
    final sloshX = controller.sloshX * R * 0.10;
    final sloshY = controller.sloshY * R * 0.10;

    // sampler 索引 0；浮点 uniforms 从 0 开始。
    shader.setImageSampler(0, img);
    shader.setFloat(0, img.width.toDouble());
    shader.setFloat(1, img.height.toDouble());
    shader.setFloat(2, orbX * dpr);
    shader.setFloat(3, cy * dpr);
    shader.setFloat(4, R * dpr);
    shader.setFloat(5, amount);
    shader.setFloat(6, bezel);
    shader.setFloat(7, disp);
    shader.setFloat(8, sloshX * dpr);
    shader.setFloat(9, sloshY * dpr);

    final paint = Paint()..shader = shader;
    final box = R * 1.02;
    final rect = Rect.fromCenter(
      center: Offset(orbX, cy),
      width: box * 2,
      height: box * 2,
    );
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant LensPainter oldDelegate) => true;
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double _lerpRange(double x, double x0, double x1, double y0, double y1) {
  if (x1 == x0) return y0;
  final t = (x - x0) / (x1 - x0);
  return y0 + (y1 - y0) * t;
}
