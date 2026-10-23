import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:miru/utils/theme.dart';

/// v2：按压弹簧缩放（不参与手势竞技场）。
///
/// 与 [PressableGlass] 同一套弹簧手感，但用 [Listener] 监听原始指针
/// 事件——可以包在任何已有 InkWell/GestureDetector 外层而不抢点击、
/// 不改变命中语义。手指移出/滚动取消时回弹。
class SpringPress extends StatefulWidget {
  const SpringPress({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
    this.enabled = true,
  });

  final Widget child;
  final double pressedScale;
  final bool enabled;

  @override
  State<SpringPress> createState() => _SpringPressState();
}

class _SpringPressState extends State<SpringPress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    lowerBound: -0.25,
    upperBound: 1.25,
  );

  void _to(double target) {
    if (!widget.enabled) return;
    _press.animateWith(SpringSimulation(Motion.snappy, _press.value, target, 0));
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _to(1),
      onPointerUp: (_) => _to(0),
      onPointerCancel: (_) => _to(0),
      // 拖动超过触摸阈值（滚动列表）立即回弹，不做“按住”假象。
      onPointerMove: (e) {
        if (e.delta.distanceSquared > 4 && _press.value > 0.5) _to(0);
      },
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) => Transform.scale(
          scale: 1.0 - (1.0 - widget.pressedScale) * _press.value,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
