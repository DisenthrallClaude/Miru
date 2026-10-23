import 'package:flutter/material.dart';

/// 列表/网格的「错峰入场」（P2-6）。
///
/// 一组元素首次出现时，按序号错开 [step] 依次淡入并上浮 [rise] 像素，
/// 形成从左上到右下的节奏波，而不是整块硬切。
///
/// 只在「这一组刚出现」时生效：调用方传入这一组的诞生时刻 [epoch]
/// （例如切换线路/打开面板的那一刻）；超过 [window] 之后才被构建的元素
/// （滚动进入视口的懒加载项）直接静止呈现，不会在滚动时反复闪动。
/// 序号超过 [maxStaggered] 的元素共享最后一档延迟，长列表不会拖尾。
///
/// 纯视觉：不包 IgnorePointer、不改变布局尺寸，入场过程中照样可点。
class StaggeredReveal extends StatefulWidget {
  const StaggeredReveal({
    super.key,
    required this.index,
    required this.epoch,
    required this.child,
    this.step = const Duration(milliseconds: 22),
    this.duration = const Duration(milliseconds: 360),
    this.rise = 10,
    this.maxStaggered = 24,
    this.window = const Duration(milliseconds: 700),
    this.enabled = true,
  });

  final int index;
  final DateTime epoch;
  final Widget child;
  final Duration step;
  final Duration duration;
  final double rise;
  final int maxStaggered;
  final Duration window;
  final bool enabled;

  /// 纯函数：给定构建时刻是否需要入场动画、延迟多久（单测锁定）。
  static Duration? delayFor({
    required int index,
    required DateTime epoch,
    required DateTime now,
    Duration step = const Duration(milliseconds: 22),
    int maxStaggered = 24,
    Duration window = const Duration(milliseconds: 700),
  }) {
    if (now.difference(epoch) > window) return null;
    final int slot = index.clamp(0, maxStaggered);
    return step * slot;
  }

  @override
  State<StaggeredReveal> createState() => _StaggeredRevealState();
}

class _StaggeredRevealState extends State<StaggeredReveal>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) return;
    final Duration? delay = StaggeredReveal.delayFor(
      index: widget.index,
      epoch: widget.epoch,
      now: DateTime.now(),
      step: widget.step,
      maxStaggered: widget.maxStaggered,
      window: widget.window,
    );
    if (delay == null) return;
    final c = AnimationController(vsync: this, duration: widget.duration);
    _c = c;
    Future<void>.delayed(delay, () {
      if (mounted) c.forward();
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) {
        final double t = Curves.easeOutCubic.transform(c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.rise * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}
