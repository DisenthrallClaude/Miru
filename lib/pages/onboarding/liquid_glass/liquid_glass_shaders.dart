import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

/// 液态玻璃欢迎屏的 shader 加载与缓存。
///
/// frag 文件在 pubspec 的 `flutter.shaders` 注册，编译后随包分发：
/// * `liquid_glass_glass.frag` —— 玻璃球光影（CustomPaint 全屏画）。
/// * `liquid_glass_lens_backdrop.frag` —— 真实 BackdropFilter 折射
///   （Impeller 专用；透镜把背景+贴纸真实弯折，与原版一致）。
/// * `liquid_glass_lens.frag` —— 回退路径：Astro 静态星空预捕获贴图采样。
class LiquidGlassShaders {
  LiquidGlassShaders._();

  static ui.FragmentProgram? _glass;
  static ui.FragmentProgram? _lens;
  static ui.FragmentProgram? _lensBackdrop;
  static ui.FragmentShader? _glassInstance;

  /// 玻璃球（穹顶/+ 按钮）光影 shader —— 复用单例（每帧重设 uniform）。
  static ui.FragmentShader? glass() {
    if (_glassInstance != null) return _glassInstance;
    final program = _glass;
    if (program == null) return null;
    return _glassInstance = program.fragmentShader();
  }

  /// 透镜折射 shader（回退：sampler = 预捕获的场景）——单例复用。
  static ui.FragmentShader? _lensInstance;

  static ui.FragmentShader? lens() {
    if (_lensInstance != null) return _lensInstance;
    final program = _lens;
    if (program == null) return null;
    return _lensInstance = program.fragmentShader();
  }

  /// 透镜折射 shader（回退：sampler = 预捕获的场景）。
  static ui.FragmentShader? createLens() {
    final program = _lens;
    if (program == null) return null;
    return program.fragmentShader();
  }

  /// 真实 backdrop 透镜 shader（Impeller）。
  /// 返回的实例持续复用：ImageFilter.shader 持有活动引用，
  /// 每帧只需重设 float uniform（槽位 0/1 的 sceneRes 由引擎写入）。
  static ui.FragmentShader? _lensBackdropInstance;

  static ui.FragmentShader? lensBackdrop() {
    if (_lensBackdropInstance != null) return _lensBackdropInstance;
    final program = _lensBackdrop;
    if (program == null) return null;
    return _lensBackdropInstance = program.fragmentShader();
  }

  /// 当前渲染后端是否支持 ImageFilter.shader（Impeller）。
  static bool get isBackdropLensSupported =>
      _lensBackdrop != null && ui.ImageFilter.isShaderFilterSupported;

  /// 预加载 shader；失败返回 false（调用方降级为近似透镜）。
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
    try {
      _lensBackdrop ??= await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass_lens_backdrop.frag',
      );
      // 预检 uniform 契约（首个 vec2 + sampler）并保留实例。
      lensBackdrop();
      if (ui.ImageFilter.isShaderFilterSupported) {
        // 预检 ImageFilter.shader 的布局校验；失败则走回退路径。
        // ignore: avoid_catching_errors
        try {
          ui.ImageFilter.shader(lensBackdrop()!);
        } catch (_) {
          _lensBackdrop = null;
          _lensBackdropInstance = null;
        }
      }
    } catch (_) {
      _lensBackdrop = null;
    }
    return ok;
  }

  /// 把一张 asset 图片按 cover 布局渲染成与屏幕物理像素同尺寸的
  /// ui.Image —— 回退路径下 Astro 静态星空的透镜场景捕获。
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
