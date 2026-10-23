import 'package:flutter/material.dart';
import 'package:miru/bean/widget/spring_press.dart';
import 'package:miru/utils/haptics.dart';

/// v1.8.1：首页分类条（液态玻璃胶囊）。
///
/// 横向滚动；选中项是一颗带高光描边、内侧镜面渐变的玻璃胶囊，
/// 切换时胶囊尺寸/色彩做柔和过渡（不做 BackdropFilter——整条只用
/// 装饰层模拟玻璃，几十个胶囊也不增加 GPU 采样开销，低端机友好）。
/// 选中项会自动滚到可见区域中间。
class GlassCategoryBar extends StatefulWidget {
  const GlassCategoryBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.height = 44,
  });

  /// 展示名列表；空串表示「推荐」。
  final List<String> items;
  final String selected;
  final ValueChanged<String> onSelected;
  final double height;

  @override
  State<GlassCategoryBar> createState() => _GlassCategoryBarState();
}

class _GlassCategoryBarState extends State<GlassCategoryBar> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};

  GlobalKey _keyOf(String s) => _keys.putIfAbsent(s, GlobalKey.new);

  @override
  void didUpdateWidget(covariant GlassCategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void _reveal() {
    final ctx = _keyOf(widget.selected).currentContext;
    if (ctx == null || !mounted) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: widget.items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final item = widget.items[i];
          return KeyedSubtree(
            key: _keyOf(item),
            child: _GlassChip(
              label: item.isEmpty ? '推荐' : item,
              selected: item == widget.selected,
              onTap: () {
                if (item == widget.selected) return;
                MiruHaptics.select();
                widget.onSelected(item);
              },
            ),
          );
        },
      ),
    );
  }
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isLight = theme.brightness == Brightness.light;
    final radius = BorderRadius.circular(999);
    final Color fill = selected
        ? scheme.primary.withValues(alpha: isLight ? 0.16 : 0.30)
        : scheme.onSurface.withValues(alpha: isLight ? 0.05 : 0.08);
    final Color stroke = selected
        ? scheme.primary.withValues(alpha: isLight ? 0.50 : 0.62)
        : (isLight
            ? scheme.onSurface.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.14));
    return Semantics(
      selected: selected,
      button: true,
      child: SpringPress(
        pressedScale: 0.94,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: stroke, width: selected ? 1.1 : 0.8),
              // 镜面高光：上缘亮、下缘透，模拟玻璃的折射边
              // （BoxDecoration 有 gradient 时 color 不生效，故把底色并进渐变）
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                      Colors.white.withValues(
                          alpha: selected
                              ? (isLight ? 0.45 : 0.14)
                              : (isLight ? 0.30 : 0.05)),
                      fill),
                  fill,
                ],
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.18),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: theme.textTheme.labelLarge!.copyWith(
                fontSize: 14,
                height: 1.1,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.72),
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}
