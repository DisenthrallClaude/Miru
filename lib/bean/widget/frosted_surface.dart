import 'dart:ui';

import 'package:cupertino_liquid_glass/cupertino_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/utils/theme.dart';

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
class FrostedSurface extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;

    if (!enabled) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: borderRadius,
          border: border,
        ),
        child: child,
      );
    }

    final double opacity = Frost.tintOpacity(brightness);

    Widget glass;
    if (liquid) {
      glass = CupertinoLiquidGlass(
        blurSigma: blur,
        tintOpacity: opacity,
        borderRadius: borderRadius ?? BorderRadius.zero,
        // 显式给足边缘高光与镜面渐变，否则默认参数下几乎看不出玻璃感
        edgeLightColor: Frost.edgeLight(brightness),
        edgeShadowColor: Frost.edgeShadow(brightness),
        specularGradient: Frost.specular(brightness),
        borderWidth: 1.0,
        child: child,
      );
    } else {
      // 朴素模糊兜底。BackdropFilter 必须被裁剪到自身边界内，
      // 否则会模糊整个图层（表现为全屏发虚）。
      final Color base =
          tint ?? scheme.surface.withValues(alpha: opacity);
      glass = ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(color: base),
            child: child,
          ),
        ),
      );
    }

    if (border == null) return glass;
    // 描边画在玻璃之外
    return DecoratedBox(
      decoration: BoxDecoration(border: border, borderRadius: borderRadius),
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
