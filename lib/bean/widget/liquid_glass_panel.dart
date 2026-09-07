import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 预加载液态玻璃面板 shader（main.dart 启动时 await——首帧前就绪，
/// 底部 Dock 不会先闪一下毛玻璃再变折射玻璃）。
Future<void> preloadLiquidGlassPanel() =>
    _LiquidGlassPanelState._loadProgram();

/// 顶尖液态玻璃面板（v1.6.4）——把开屏页那套「真实折射玻璃」带进
/// 应用内主界面。
///
/// 渲染管线（v1.6.6 双 pass 磨砂架构，参考 liquid_glass_easy 组件的
/// 组合方式）：
/// ```
/// ClipRRect > RepaintBoundary > Stack (
///   pass 1: BackdropFilter(ImageFilter.blur(frostSigma))   // 全通道磨砂基底
///   pass 2: BackdropFilter(ImageFilter.shader) > child      // 折射/rim/色散
/// )
/// ```
/// 两个 BackdropFilter 叠放会链式采样：pass 2 的着色器读到的是
/// **已被 pass 1 模糊过的背景**——背景先磨砂、再折射，而不是
/// 「折射清晰图像后再模糊」。
///
/// v1.6.6 可读性根因修复：v1.6.5 的 shader 只有绿通道走 13-tap
/// 高斯，R/B 通道仍是清晰单采样——动漫封面的边缘结构透过红蓝
/// 通道依然纤毫毕现，这就是「隔着玻璃还能看清动漫」的根因。
/// 现在由引擎级 `ImageFilter.blur` 对**全部通道**做真实高斯
///（与 FrostedSurface 同源），色散/rim/高光叠加在磨砂基底之上，
/// 既是液态玻璃，也是真正的磨砂质感。
///
/// 回退路径（Skia / shader 编译失败 / `ImageFilter.shader` 不可用）：
/// 朴素 `BackdropFilter.blur` + tint + rim 高光渐变——观感降级为
/// 毛玻璃，绝不黑块。
///
/// 与 [FrostedSurface] 的分工：FrostedSurface 服务大面积卡片容器
///（保守毛玻璃）；本组件用于「主界面要发光」的少量关键件——
/// 悬浮导航 Dock、主按钮。
///
/// 约束：shader 实例全局单例（与开屏透镜同一模式——
/// `ImageFilter.shader` 持活动引用、每次 build 重设 uniform），
/// 因此【同一帧最多一个面板实例带不同参数】；当前全应用只有
/// 底部 Dock 一个实例，新增面板时需为各自创建独立实例或统一参数。
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
    this.frostSigma = 28,
    this.glassBlur = 0,
    this.blurSigma = 28,
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

  /// 玻璃体乳白度（默认主题感知，v1.6.6 提亮：亮 0.45 / 暗 0.55，
  /// 消除与全局 Frost 体系的层级倒挂）。
  final double? tintAmt;

  /// v1.6.6：引擎级全通道高斯模糊 sigma（逻辑 dp）——磨砂基底。
  /// 这是可读性的第一道防线：R/G/B **全部**化开，背景只剩色彩
  /// 呼吸，任何封面的边缘结构都无法透过玻璃辨认。着色器叠加其
  /// 上做折射/色散，形成「磨砂液态玻璃」。参考 liquid_glass_easy
  /// 的双 BackdropFilter 链式组合（blur 先、shader 后）。
  final double frostSigma;

  /// v1.6.6：着色器内附加模糊（物理 px = dp × dpr）。默认 0——
  /// 磨砂由 [frostSigma] 的引擎模糊全权负责；此参数仅供微调
  ///（若需要 rim 附近额外柔化可给小值）。
  final double glassBlur;

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
    // v1.6.6：乳白度 亮 0.38→0.45 / 暗 0.50→0.55——消除与全局
    // Frost 体系的层级倒挂（Dock 不再是全应用最「清」的玻璃）；
    // 纯折射无模糊时会被背景冲刷（FrostedSurface 注释里记录过
    // 同一教训），配合引擎级全通道高斯双保险，页签文字在任何
    // 封面下都读得清。
    final double tintAmt = widget.tintAmt ??
        (brightness == Brightness.dark ? 0.55 : 0.45);

    final shader = _shaderInstance;
    if (_program != null && shader != null) {
      // 槽位：0/1 = sceneRes（引擎写入，不设置）；
      // 2 = radius；3 = thickness；4 = dispersion；5 = highlight；
      // 6/7/8 = tintColor；9 = tintAmt；10 = blur（物理 px）。
      shader.setFloat(2, widget.radius * dpr);
      shader.setFloat(3, widget.thickness);
      shader.setFloat(4, widget.dispersion);
      shader.setFloat(5, widget.highlight);
      shader.setFloat(6, tint.r);
      shader.setFloat(7, tint.g);
      shader.setFloat(8, tint.b);
      shader.setFloat(9, tintAmt);
      shader.setFloat(10, widget.glassBlur * dpr);

      // v1.6.6 双 pass（liquid_glass_easy 架构）：
      // pass 1 = 引擎级全通道高斯（磨砂基底，R/G/B 全化开）；
      // pass 2 = 折射着色器，读到的是已磨砂的背景——背景先磨砂
      // 再折射，rim 色散与顶部高光叠在柔基底上。
      //
      // ⚠️ 结构约束（勿破坏）：
      // ① RepaintBoundary 包住【整个 Stack】——两个 filter 之间
      //   不得再插入任何 Boundary/裁剪层，否则 pass 2 的 readback
      //   读不到 pass 1 的输出，链式断裂；
      // ② pass 2 必须是非定位 child 撑起 Stack 尺寸（面板高度 =
      //   child 高度）；pass 1 用 Positioned.fill 铺满即可——若
      //   全部子节点都是 positioned，RenderStack 会取
      //   constraints.biggest，Dock 尺寸语义回归；
      // ③ pass 1 用 TileMode.clamp（非 decal）——decal 在边缘带
      //   alpha 衰减，未磨砂内容会从玻璃边缘漏出。
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: RepaintBoundary(
          child: Stack(
            children: [
              // pass 1：磨砂基底（Positioned.fill 铺满 Stack，Stack 尺寸
              // 由 pass 2 的 child 决定）。IgnorePointer 保证不抢手势。
              // clamp 复制边缘像素、alpha 恒 1，不留漏缝。
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: widget.frostSigma,
                      sigmaY: widget.frostSigma,
                      tileMode: TileMode.clamp,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // pass 2：液态玻璃折射着色器（读取已磨砂背景）。
              // 非定位 child——决定 Stack 尺寸，恢复「面板高度 =
              // child 高度」的 v1.6.5 语义。
              BackdropFilter(
                filter: ui.ImageFilter.shader(shader),
                child: widget.child,
              ),
            ],
          ),
        ),
      );
    }

    // 回退：毛玻璃 + rim 渐变（观感降级但不破相）。
    // 模糊强度与主路径同源（frostSigma），保证回退观感不漂移。
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: widget.blurSigma,
          sigmaY: widget.blurSigma,
          tileMode: TileMode.clamp,
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
/// 折射 + 高斯模糊（v1.6.5），rim 色散随内容亮度变化，顶部内侧
/// 高光始终读得出「一块厚玻璃」。
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
        // v1.6.6：磨砂基底交给引擎级全通道高斯（frostSigma 默认 22），
        // 着色器内模糊归零——这是文字与图标常驻的关键件，任何封面
        // 滚过都必须化开到只剩色彩呼吸。
        glassBlur: 0,
        child: SizedBox(height: height, child: child),
      ),
    );
  }
}
