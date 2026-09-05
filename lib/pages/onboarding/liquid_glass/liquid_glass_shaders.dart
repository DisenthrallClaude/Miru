import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

/// 液态玻璃欢迎屏的 shader 加载与缓存。
///
/// frag 文件在 pubspec 的 `flutter.shaders` 注册，编译后随包分发；
/// lens shader 的场景贴图由调用方捕获（Astro 静态星空）。
class LiquidGlassShaders {
  LiquidGlassShaders._();

  static ui.FragmentProgram? _glass;
  static ui.FragmentProgram? _lens;

  /// 玻璃球（穹顶/+ 按钮）光影 shader。
  static ui.FragmentShader? createGlass() {
    final program = _glass;
    if (program == null) return null;
    return program.fragmentShader();
  }

  /// 透镜折射 shader（sampler = 预捕获的场景）。
  static ui.FragmentShader? createLens() {
    final program = _lens;
    if (program == null) return null;
    return program.fragmentShader();
  }

  /// 预加载两个 shader；失败返回 false（调用方降级为纯色玻璃）。
  static Future<bool> preload() async {
    var ok = true;
    try {
      _glass ??= await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass_glass.frag',
      );
    } catch (_) {
      ok = false;
    }
    try {
      _lens ??= await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass_lens.frag',
      );
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  /// 把一张 asset 图片按 cover 布局渲染成与屏幕物理像素同尺寸的
  /// ui.Image —— Astro 静态星空的透镜场景捕获。
  static Future<ui.Image?> captureCoverScene({
    required String asset,
    required double widthLogical,
    required double heightLogical,
    required double dpr,
  }) async {
    try {
      final data = await rootBundle.load(asset);
      final src = await ui.ImmutableBuffer.fromUint8List(
        data.buffer.asUint8List(),
      );
      final descriptor = await ui.ImageDescriptor.encoded(src);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      final w = (widthLogical * dpr).round();
      final h = (heightLogical * dpr).round();
      if (w <= 0 || h <= 0) return null;

      // cover：居中裁剪源图。
      final srcW = srcImage.width.toDouble();
      final srcH = srcImage.height.toDouble();
      final scale = math.max(w / srcW, h / srcH);
      final visibleW = w / scale;
      final visibleH = h / scale;
      final srcRect = ui.Rect.fromLTRB(
        (srcW - visibleW) / 2,
        (srcH - visibleH) / 2,
        (srcW + visibleW) / 2,
        (srcH + visibleH) / 2,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        srcImage,
        srcRect,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      return picture.toImageSync(w, h);
    } catch (_) {
      return null;
    }
  }
}
