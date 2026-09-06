import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 预加载液态玻璃面板 shader（main.dart 启动时 await——首帧前就绪，
/// 底部 Dock 不会先闪一下毛玻璃再变折射玻璃）。
Future<void> preloadLiquidGlassPanel() =>
    _LiquidGlassPanelState._loadProgram();

/// 顶尖液态玻璃面板（v1.6.4）——把开屏页那套「真实折射玻璃」带进
/// 应用内主界面。
///
/// 渲染管线（Impeller 路径）：
/// `ClipRRect > BackdropFilter(ImageFilter.shader) > [tint + rim 光效]`
/// shader（`liquid_glass_panel.frag`）对 backdrop 做真实的圆角矩形
/// 折射：内容在玻璃下被弯折放大、rim 处的 bevel 拉扯更强、RGB 三
/// 通道在 rim 色散、顶部内侧镜面高光、底部接地阴影线——与开屏
/// 玻璃穹顶同一物理观感，只是几何从圆球换成了圆角矩形板。
///
/// 回退路径（Skia / shader 编译失败 / `ImageFilter.shader` 不可用）：
/// 朴素 `BackdropFilter.blur` + tint + rim 高光渐变——观感降级为
/// 毛玻璃，绝不黑块。
///
/// 与 [FrostedSurface] 的分工：FrostedSurface 服务大面积卡片容器
///（保守毛玻璃）；本组件用于「主界面要发光」的少量关键件——
/// 悬浮导航 Dock、主按钮。
class LiquidGlassPanel extends StatefulWidget {
  const LiquidGlassPanel({
    super.key,
    required this.child,
    required this.radius,
    this.thickness = 0.85,
    this.dispersion = 0.014,
    this.highlight = 0.16,
    this.tint,
    this.tintAmt,
    this.blurSigma = 18,
  });

  final Widget child;

  /// 圆角半径（逻辑 px）。
  final double radius;

  /// 玻璃厚度（折射强度 0..1）。
  final double thickness;

  /// rim 色散强度。
  final double dispersion;

  /// 顶部内侧高光强度。
  final double highlight;

  /// 覆盖玻璃体 tint 色（默认主题感知）。
  final Color? tint;

  /// 玻璃体乳白度（默认主题感知）。
  final double? tintAmt;

  /// 回退路径的高斯模糊 sigma。
  final double blurSigma;

  @override
  State<LiquidGlassPanel> createState() => _LiquidGlassPanelState();
}

class _LiquidGlassPanelState extends State<LiquidGlassPanel> {
  @override
  void initState() {
    super.initState();
    _ensureProgramLoaded();
  }

  static ui.FragmentProgram? _program;
  static ui.FragmentShader? _shaderInstance;
  static bool _loadAttempted = false;

  static void _ensureProgramLoaded() {
    if (!_loadAttempted) {
      _loadProgram();
    }
  }

  static Future<void> _loadProgram() async {
    if (_loadAttempted) return;
    _loadAttempted = true;
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass_panel.frag',
      );
      // 预检 uniform 布局（首个 vec2 + sampler 契约）；布局不符时
      // 降级回退路径而不是渲染期反复报错。
      final shader = program.fragmentShader();
      ui.ImageFilter.shader(shader);
      if (!ui.ImageFilter.isShaderFilterSupported) {
        return;
      }
      _program = program;
      _shaderInstance = shader;
    } catch (_) {
      // 回退路径。
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final Color tint = widget.tint ??
        (brightness == Brightness.dark
            ? const Color(0xFF141A22)
            : const Color(0xFFF4F8FC));
    final double tintAmt = widget.tintAmt ??
        (brightness == Brightness.dark ? 0.42 : 0.30);

    final shader = _shaderInstance;
    if (_program != null && shader != null) {
      // 槽位：0/1 = sceneRes（引擎写入，不设置）；
      // 2 = radius；3 = thickness；4 = dispersion；5 = highlight；
      // 6/7/8 = tintColor。
      shader.setFloat(2, widget.radius * dpr);
      shader.setFloat(3, widget.thickness);
      shader.setFloat(4, widget.dispersion);
      shader.setFloat(5, widget.highlight);
      shader.setFloat(6, tint.r);
      shader.setFloat(7, tint.g);
      shader.setFloat(8, tint.b);
      shader.setFloat(9, tintAmt);

      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.shader(shader),
          child: widget.child,
        ),
      );
    }

    // 回退：毛玻璃 + rim 渐变（观感降级但不破相）。
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: widget.blurSigma,
          sigmaY: widget.blurSigma,
          tileMode: TileMode.decal,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint.withValues(alpha: tintAmt),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(
                    alpha: brightness == Brightness.dark ? 0.10 : 0.35),
                Colors.white.withValues(alpha: 0.0),
                Colors.black.withValues(
                    alpha: brightness == Brightness.dark ? 0.16 : 0.04),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
            border: Border.all(
              color: brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.55),
              width: 0.8,
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 悬浮液态玻璃 Dock：主界面底部导航的「顶尖玻璃」容器（v1.6.4）。
///
/// 与旧 FrostedBar 的贴边毛玻璃条不同，Dock 是一块悬浮的圆角玻璃
/// 板（左右留边、底部安全区之上浮起）——内容从其下滚过时被真实
/// 折射，rim 色散随内容亮度变化，顶部内侧高光始终读得出「一块
/// 厚玻璃」。
class LiquidGlassDock extends StatelessWidget {
  const LiquidGlassDock({
    super.key,
    required this.child,
    this.height = 74,
    this.horizontalMargin = 14,
    this.bottomMargin = 12,
    this.radius = 30,
  });

  final Widget child;
  final double height;
  final double horizontalMargin;
  final double bottomMargin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: horizontalMargin,
        right: horizontalMargin,
        // 悬浮于手势区之上；手势区高度不足时贴安全区。
        bottom: bottomMargin + (bottomInset > 0 ? bottomInset : 6),
      ),
      child: LiquidGlassPanel(
        radius: radius,
        thickness: 0.9,
        highlight: 0.18,
        child: SizedBox(height: height, child: child),
      ),
    );
  }
}
