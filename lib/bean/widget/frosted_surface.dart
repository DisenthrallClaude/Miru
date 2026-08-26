import 'dart:ui';

import 'package:cupertino_liquid_glass/cupertino_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:miru/utils/theme.dart';

/// 毛玻璃 / 液态玻璃材质容器。
///
/// 对外 API 保持不变，内部实现委托给 `cupertino_liquid_glass`，
/// 因此所有调用点无需任何改动即可获得 iOS 26 的 Liquid Glass 观感
/// （模糊 + 边缘高光 + 镜面渐变）。
///
/// 该包不含自定义片元着色器，只用 `BackdropFilter` + 渐变实现，
/// 与原先的手写实现是同一类渲染开销，不会引入额外的 GPU 负担。
///
/// [liquid] 置 false 时退回朴素模糊，供低端机或出现掉帧时降级使用。
///
/// ## 为什么是 StatefulWidget
///
/// `BackdropFilter` 采样的是「合成时背后图层已画好的像素」。两个已知
/// 时机问题会让首屏玻璃没有模糊、要点一下才出现：
///
/// 1. 玻璃与背后内容同帧首次入场时，backdrop 的采样早于背后内容
///    进入图层（Skia 合成顺序问题），首帧只画得出 tint；
/// 2. 路由转场（渐隐 / 渐隐+位移）用 `Opacity` saveLayer 实现，
///    alpha<1 期间 BackdropFilter 采到的是 saveLayer 内的空白，
///    转场结束后图层的 backdrop 结果被缓存，不会自动重新采样。
///
/// 两种情况靠「事后强制重挂一次玻璃子树」解决：换 key 重建会生成
/// 全新的 layer，backdrop 从此以正确的背景重采样。为此监听两个
/// 时机：首帧完成 + 宿主路由转场完成。
class FrostedSurface extends StatefulWidget {
  const FrostedSurface({
    super.key,
    required this.child,
    this.blur = Frost.blur,
    this.borderRadius,
    this.tint,
    this.border,
    this.enabled = true,
    this.liquid = true,
  });

  final Widget child;

  /// 高斯模糊半径。
  final double blur;

  /// 圆角。给定时会裁剪模糊区域，避免模糊溢出到圆角外。
  final BorderRadius? borderRadius;

  /// 覆盖默认的半透明底色。
  final Color? tint;

  /// 可选描边。画在玻璃层之外，避免干扰其内部的裁剪与采样。
  final BoxBorder? border;

  /// 关闭后退化为普通不透明容器。
  final bool enabled;

  /// 是否启用液态玻璃（边缘高光 / 镜面渐变）。
  final bool liquid;

  @override
  State<FrostedSurface> createState() => _FrostedSurfaceState();
}

class _FrostedSurfaceState extends State<FrostedSurface> {
  /// 玻璃子树重建纪元。自增即换 key 强制重挂 layer，
  /// 让 BackdropFilter 以当前真实背景重新采样。
  int _epoch = 0;

  /// 路由转场动画宿主。TransitionRoute 才有 [TransitionRoute.animation]，
  /// ModalRoute.of 的返回值可安全向上转型到这里。
  TransitionRoute<void>? _watchedRoute;

  @override
  void initState() {
    super.initState();
    // 时机一：首帧渲染完成后立刻补一帧。
    // 覆盖「玻璃与背后内容同帧入场、backdrop 采到空」的情况。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _epoch++);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _watchedRoute)) {
      return;
    }
    _watchedRoute?.animation?.removeStatusListener(_onRouteStatus);
    _watchedRoute = route;
    // 时机二：宿主路由转场完成后再补一帧。
    // 覆盖「转场期间 Opacity saveLayer 导致 backdrop 采到空白」的情况。
    // 已完成（无动画/直推路由）则无需处理，时机一已覆盖。
    route?.animation?.addStatusListener(_onRouteStatus);
  }
  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _epoch++);
    }
  }

  @override
  void dispose() {
    _watchedRoute?.animation?.removeStatusListener(_onRouteStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;

    if (!widget.enabled) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: widget.borderRadius,
          border: widget.border,
        ),
        child: widget.child,
      );
    }

    final double opacity = Frost.tintOpacity(brightness);
    // 局部变量承接可空字段：Dart 的类型提升对实例字段无效。
    final Color? tintColor = widget.tint;

    // cupertino_liquid_glass 内部已插入 RepaintBoundary 隔离合成层，
    // 这里不再重复包裹，避免多一次离屏栅格缓存。
    Widget glass;
    if (widget.liquid) {
      glass = CupertinoLiquidGlass(
        blurSigma: widget.blur,
        tintOpacity: opacity,
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
        // 显式给足边缘高光与镜面渐变，否则默认参数下几乎看不出玻璃感
        edgeLightColor: Frost.edgeLight(brightness),
        edgeShadowColor: Frost.edgeShadow(brightness),
        specularGradient: Frost.specular(brightness),
        borderWidth: 1.0,
        child: tintColor == null
            ? widget.child
            // tint 在液态分支以覆盖层形式生效，让调用方可以微调玻璃色调
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: tintColor.withValues(alpha: 0.35),
                  borderRadius: widget.borderRadius,
                ),
                child: widget.child,
              ),
      );
      // 外层 RepaintBoundary：把玻璃隔离成独立合成层；key 携带重建纪元，
      // 纪元变化即整棵子树重挂（新 layer + backdrop 重采样）。
      glass = RepaintBoundary(
        key: ValueKey('frost-glass-$_epoch'),
        child: glass,
      );
    } else {
      // 朴素模糊兜底。BackdropFilter 必须被裁剪到自身边界内，
      // 否则会模糊整个图层（表现为全屏发虚）。
      final Color base =
          tintColor ?? scheme.surface.withValues(alpha: opacity);
      glass = ClipRRect(
        key: ValueKey('frost-plain-$_epoch'),
        borderRadius: widget.borderRadius ?? BorderRadius.zero,
        child: BackdropFilter(
          filter: ImageFilter.blur(
              sigmaX: widget.blur, sigmaY: widget.blur),
          child: DecoratedBox(
            decoration: BoxDecoration(color: base),
            child: widget.child,
          ),
        ),
      );
    }

    if (widget.border == null) return glass;
    // 描边画在玻璃之外
    return DecoratedBox(
      decoration: BoxDecoration(
          border: widget.border, borderRadius: widget.borderRadius),
      child: glass,
    );
  }
}

/// 顶部带一条发丝分隔线的玻璃条，用于底部导航一类的贴边容器。
class FrostedBar extends StatelessWidget {
  const FrostedBar({
    super.key,
    required this.child,
    this.showTopDivider = true,
    this.liquid = true,
  });

  final Widget child;
  final bool showTopDivider;
  final bool liquid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostedSurface(
      liquid: liquid,
      border: showTopDivider
          ? Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5))
          : null,
      child: child,
    );
  }
}
