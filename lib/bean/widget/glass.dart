import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/frosted_surface.dart';
import 'package:kazumi/utils/theme.dart';

/// 玻璃强度。
///
/// 这个区分是**性能设计**，不只是视觉分级：
/// * [GlassLevel.heavy] 走真实的 `BackdropFilter`（会采样并模糊背后内容），
///   观感最强但每个实例都有 GPU 开销，只用在常用的大面积交互面上
///   —— 导航条、顶栏、浮层、选中罩。
/// * [GlassLevel.light] **不做模糊**，只用半透明底 + 镜面渐变 + 发丝描边
///   模拟玻璃质感，开销接近于零。因此可以放心大量使用
///   —— 标签、小徽标、次要按钮、区块标题等。
///
/// 如果所有元素都用 heavy，一屏几十个 `BackdropFilter` 会直接把帧率打下来，
/// 这也是「全局玻璃」唯一可行的落地方式。
enum GlassLevel { light, heavy }

/// 通用玻璃容器。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.level = GlassLevel.light,
    this.borderRadius,
    this.padding,
    this.tinted = false,
  });

  final Widget child;
  final GlassLevel level;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;

  /// 是否带一点强调色（用于选中态）。
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final radius = borderRadius ?? Radii.brSm;

    final content =
        padding == null ? child : Padding(padding: padding!, child: child);

    if (level == GlassLevel.heavy) {
      return FrostedSurface(borderRadius: radius, child: content);
    }

    // 轻度：无模糊，纯装饰层模拟玻璃
    final bool isLight = brightness == Brightness.light;
    // 提高底色与描边强度：之前太淡，观感上「看不出有圆盘」
    final Color base = tinted
        ? scheme.primary.withValues(alpha: isLight ? 0.16 : 0.26)
        : scheme.onSurface.withValues(alpha: isLight ? 0.09 : 0.14);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: base,
        borderRadius: radius,
        border: Border.all(
          color: tinted
              ? scheme.primary.withValues(alpha: isLight ? 0.45 : 0.55)
              : (isLight
                  // 亮色下用「暗描边」才看得见边界，纯白描边在白底上等于没有
                  ? scheme.onSurface.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.22)),
          width: 1.0,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: isLight ? 0.55 : 0.14),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.75],
        ),
      ),
      child: content,
    );
  }
}

/// 轻度玻璃「药丸」，用于标签、徽标、区块标题一类的小元素。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.selected = false,
    this.onTap,
    this.padding =
        const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final pill = GlassSurface(
      level: GlassLevel.light,
      borderRadius: Radii.brSm,
      padding: padding,
      tinted: selected,
      child: child,
    );

    if (onTap == null) return pill;
    return InkWell(
      borderRadius: Radii.brSm,
      onTap: onTap,
      child: pill,
    );
  }
}

/// 供 `TabBar.indicator` 使用的玻璃指示器装饰。
///
/// 用于**可滚动**的 TabBar：各页签宽度不等，无法用均分槽位定位玻璃块，
/// 因此交给 TabBar 自带的 indicator 机制（宽度自适应、动画由它负责）。
/// 这里是轻度玻璃——纯装饰无模糊，所以放在滑动的标签栏里也不吃性能。
Decoration glassTabIndicator(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isLight = theme.brightness == Brightness.light;
  return BoxDecoration(
    color: scheme.primary.withValues(alpha: isLight ? 0.10 : 0.20),
    borderRadius: Radii.brSm,
    border: Border.all(
      color: scheme.primary.withValues(alpha: isLight ? 0.26 : 0.38),
      width: 0.8,
    ),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: isLight ? 0.30 : 0.10),
        Colors.white.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.7],
    ),
  );
}

/// 玻璃图标圆盘。
///
/// 把小图标（设置项、历史记录、下载等处的 icon）统一放进一枚玻璃圆盘里，
/// 质感与底部导航条的玻璃滑块一致。默认轻度（无模糊、零开销），
/// 因此可以在长列表里大量使用。
class GlassIconDisc extends StatelessWidget {
  const GlassIconDisc({
    super.key,
    required this.icon,
    this.size = 36,
    this.iconSize = 18,
    this.color,
    this.tinted = false,
  });

  final IconData icon;

  /// 圆盘直径。
  final double size;
  final double iconSize;

  /// 图标颜色，默认取 onSurfaceVariant。
  final Color? color;

  /// 带强调色调（用于选中/主要入口）。
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(size / 2),
        tinted: tinted,
        child: Center(
          child: Icon(
            icon,
            size: iconSize,
            color: color ?? (tinted ? scheme.primary : scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// 玻璃质感的扩展型悬浮按钮（用于「开始观看」「发表吐槽」等主要动作）。
///
/// 用**重度**玻璃：它悬浮在滚动内容之上，背后确实有东西可透，
/// 而且全屏只有一个实例，开销可以接受。
class GlassActionButton extends StatelessWidget {
  const GlassActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(Radii.pill);

    final content = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Space.xl, vertical: Space.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: Space.sm),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );

    final button = FrostedSurface(borderRadius: radius, child: content);
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
