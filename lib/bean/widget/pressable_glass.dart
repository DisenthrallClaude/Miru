import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:miru/utils/theme.dart';

/// 可按压的液态玻璃容器：按下时轻微缩小，松开后以弹簧物理回弹。
///
/// 这是「顶尖交互」的基础件——iOS 26 / visionOS 的玻璃控件都带
/// 按压形变反馈。内部用 [SpringSimulation] 驱动缩放，
/// 松手瞬间有真实的过冲回弹，而不是生硬的 ease 曲线。
///
/// 用法：
/// ```dart
/// PressableGlass(
///   onTap: () => doSomething(),
///   borderRadius: Radii.brLg,
///   child: Padding(...),
/// )
/// ```
class PressableGlass extends StatefulWidget {
  const PressableGlass({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius,
    this.pressedScale = 0.96,
    this.enabled = true,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 圆角，同时决定玻璃的裁剪形状。
  final BorderRadius? borderRadius;

  /// 按压时的缩放比例，越小形变越明显。
  final double pressedScale;

  final bool enabled;

  @override
  State<PressableGlass> createState() => _PressableGlassState();
}

class _PressableGlassState extends State<PressableGlass>
    with SingleTickerProviderStateMixin {
  /// 0 = 正常态，1 = 完全按下态。
  ///
  /// 用弹簧模拟驱动：每次手势状态切换都从当前值出发，
  /// 连续快速点击时动画无缝衔接，不会跳帧；松手回弹带真实过冲。
  late final AnimationController _press = AnimationController(
    vsync: this,
    // 框架每帧会把模拟值钳制到 [lowerBound, upperBound]，
    // 紧贴 [0,1] 会裁掉弹簧的全部过冲——放宽边界给回弹留余量。
    lowerBound: -0.25,
    upperBound: 1.25,
  );

  void _animateTo(double target) {
    _press.animateWith(
      SpringSimulation(
        Motion.snappy,
        _press.value,
        target,
        0, // 落点速度归零，状态稳定
      ),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled ? (_) => _animateTo(1) : null,
      onTapUp: widget.enabled ? (_) => _animateTo(0) : null,
      onTapCancel: widget.enabled ? () => _animateTo(0) : null,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          final t = _press.value;
          final scale = 1.0 - (1.0 - widget.pressedScale) * t;
          return Transform.scale(
            scale: scale,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
