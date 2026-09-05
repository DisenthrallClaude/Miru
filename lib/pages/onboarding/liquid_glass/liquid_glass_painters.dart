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
    final shader = LiquidGlassShaders.createGlass();
    final R = controller.radius;
    final orbX = controller.orbX;
    final cy = controller.cy;
    if (R <= 0) return;

    if (shader == null) {
      // 降级：无 shader 时给一个半透明白球加 rim，不至于黑块。
      final paint = Paint()..color = _white38;
      canvas.drawCircle(Offset(orbX, cy), R, paint);
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
}

const Color _white38 = Color(0x61FFFFFF);

/// 贴纸场画笔 —— 40 贴纸 + 星尘（vortex）。
///
/// 贴纸变换序（与 RN 版 transform 数组语义一致）：
/// translate → rotate(heading) → scale(1+0.9st, 1-0.42st) →
/// rotate(-heading) → scale(scale) → rotate(rot)。
///
/// 球内贴纸的透镜放大：出生窗口内的贴纸在玻璃中被放大
/// （mag = 1 + 0.9·(1-rr)，随离球心衰减），边缘叠加 RGB 色散三层。
class StickerFieldPainter extends CustomPainter {
  StickerFieldPainter({
    required this.controller,
    required this.theme,
    required this.images,
    this.repaint,
  });

  final LiquidGlassController controller;
  final LiquidGlassTheme theme;
  final List<ui.Image?> images;
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
        final paint = Paint()
          ..color = const Color(0x61A0C8FF)
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
      final img = images[i];
      if (img == null) continue;

      final x = s[b];
      final y = s[b + 1];
      final scale = math.max(0.001, s[b + 4]);
      final heading = s[b + 11];
      final stretch = s[b + 12];
      final rot = s[b + 9];
      final slotSize = LiquidGlassController.stickerSizes[i];
      final half = slotSize / 2;

      // 球内放大（出生透过按钮玻璃的折射近似）：只在接近按钮态启用。
      final dx = x - orbX;
      final dy = y - cy;
      final dist = math.sqrt(dx * dx + dy * dy);
      var mag = 1.0;
      var chroma = 0.0;
      if (R < controller.r1 * 1.8 && R > 1 && dist < R * 1.02) {
        final rr = dist / R;
        mag = 1 + 0.9 * (1 - rr);
        chroma = disp * (1 - rr) * 0.22;
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
        _drawChannel(canvas, img, half, op, chroma,
            const [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        _drawChannel(canvas, img, half, op, 0,
            const [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        _drawChannel(canvas, img, half, op, -chroma,
            const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
      } else {
        final paint = Paint()
          ..color = Color.fromARGB(255, 255, 255, 255)
          ..filterQuality = FilterQuality.medium;
        if (op < 255) {
          paint.color = Color.fromARGB(op, 255, 255, 255);
        }
        canvas.drawImage(img, Offset(-half, -half), paint);
      }
      canvas.restore();
    }
  }

  void _drawChannel(
    Canvas canvas,
    ui.Image img,
    double half,
    int op,
    double offset,
    List<double> matrix,
  ) {
    canvas.save();
    canvas.translate(offset * half * 0.6, -offset * half * 0.15);
    final paint = Paint()
      ..color = Color.fromARGB(op, 255, 255, 255)
      ..colorFilter = ColorFilter.matrix(matrix)
      ..blendMode = BlendMode.plus
      ..filterQuality = FilterQuality.medium;
    canvas.drawImage(img, Offset(-half, -half), paint);
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
    final shader = LiquidGlassShaders.createLens();
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
