import 'package:flutter/material.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/bean/widget/pressable_glass.dart';

/// 液态玻璃版 FloatingActionButton。
///
/// v1.3.1：全应用所有浮动按钮统一替换为该组件——
/// 毛玻璃底 + 细描边 + 按压弹簧形变，几何尺寸与 Material FAB
/// 对齐（圆形 56dp / 扩展胶囊），迁移时无需调整布局。
///
/// - [GlassFab]：圆形图标按钮（等价 FloatingActionButton）
/// - [GlassFab.extended]：带文字的胶囊按钮（等价 FloatingActionButton.extended）
/// - [enabled] 为 false 时置灰且不响应点击（对应 onPressed: null）
///
/// 注意：不是 Hero，页面间无 FAB 飞行动画；设置子页面无此需求。
class GlassFab extends StatelessWidget {
  const GlassFab({
    super.key,
    required this.onTap,
    required this.icon,
    this.tooltip,
    this.enabled = true,
    this.iconSize = 24,
  })  : label = null,
        _circular = true;

  const GlassFab.extended({
    super.key,
    required this.onTap,
    required this.icon,
    required String this.label,
    this.tooltip,
    this.enabled = true,
    this.iconSize = 22,
  }) : _circular = false;

  final VoidCallback? onTap;

  /// null 等价禁用；同时显式传 [enabled] 可在保留回调的情况下置灰。
  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool enabled;
  final double iconSize;

  final bool _circular;

  static const double _circleRadius = 28; // 56dp 直径，Material FAB 标准

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool active = enabled && onTap != null;

    final Color iconColor = active
        ? (theme.iconTheme.color ?? theme.colorScheme.onSurface)
        : theme.disabledColor;

    Widget content;
    BorderRadius radius;
    if (_circular) {
      radius = BorderRadius.circular(_circleRadius);
      content = Padding(
        padding: const EdgeInsets.all(16), // (56-24)/2
        child: Icon(icon, size: iconSize, color: iconColor),
      );
    } else {
      radius = BorderRadius.circular(28);
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: iconColor),
            const SizedBox(width: 10),
            Text(
              label!,
              style: theme.textTheme.labelLarge?.copyWith(
                color: iconColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    Widget button = PressableGlass(
      onTap: active ? onTap : null,
      enabled: active,
      borderRadius: radius,
      child: FrostedSurface(
        borderRadius: radius,
        border: Border.all(
          color: theme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.55),
          width: 0.8,
        ),
        child: content,
      ),
    );

    if (tooltip != null) {
      button = Tooltip(
        message: tooltip!,
        preferBelow: false,
        child: button,
      );
    }
    return button;
  }
}
