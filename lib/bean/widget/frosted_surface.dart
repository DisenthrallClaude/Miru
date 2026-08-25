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
    // 局部变量承接可空字段：Dart 的类型提升对实例字段无效。
    final Color? tintColor = tint;

    // cupertino_liquid_glass 内部已插入 RepaintBoundary 隔离合成层，
    // 这里不再重复包裹，避免多一次离屏栅格缓存。
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
        child: tintColor == null
            ? child
            // tint 在液态分支以覆盖层形式生效，让调用方可以微调玻璃色调
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: tintColor.withValues(alpha: 0.35),
                  borderRadius: borderRadius,
                ),
                child: child,
              ),
      );
      // 外层 RepaintBoundary：把玻璃隔离成独立合成层。
      // Android Impeller 上 BackdropFilter 首次入帧时若与宿主内容同层，
      // 首帧可能只画 tint 不画模糊 —— 表现为「点一下玻璃才显现」。
      // 边界强制玻璃单独成层，backdrop 采样从首帧起就稳定。
      glass = RepaintBoundary(child: glass);
    } else {
      // 朴素模糊兜底。BackdropFilter 必须被裁剪到自身边界内，
      // 否则会模糊整个图层（表现为全屏发虚）。
      final Color base =
          tintColor ?? scheme.surface.withValues(alpha: opacity);
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
