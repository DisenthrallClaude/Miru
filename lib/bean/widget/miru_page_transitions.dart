import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Miru 的页面路由过渡（P2-2）：「纵深卡片」。
///
/// 新页面仍沿用 Cupertino 的右侧滑入——保住边缘右滑返回这条肌肉记忆
/// （CupertinoRouteTransitionMixin 自带的返回手势检测器原样保留）；
/// 区别在被覆盖的旧页面：它不再只是向左平移 1/3，而是同时
/// **后退一层**——等比缩到 0.94、四角收成 28px 圆角、蒙上一层很淡的
/// 暮色。两页之间因此有了「纸张叠放」的前后关系，配合液态玻璃的
/// 浮层语汇，转场读起来是空间运动而不是幻灯片切换。
///
/// 后退曲线：前进用 [Curves.easeOutQuart]（起步干脆、落位极柔），
/// 返回用 [Curves.easeInOutCubic]，比原 iOS 的 linearToEaseOut 少一点
/// 「甩」感，更贴近衬线体的沉静气质。时长 420/360ms，比 iOS 默认
/// 500ms 更利落。
///
/// 系统「移除动画」开启时完全退回 Cupertino 原版（不叠加纵深效果）。
class MiruPageTransitionsBuilder extends PageTransitionsBuilder {
  const MiruPageTransitionsBuilder();

  static const CupertinoPageTransitionsBuilder _base =
      CupertinoPageTransitionsBuilder();

  /// 被覆盖页面后退时的最小缩放。
  static const double recedeScale = 0.94;

  /// 被覆盖页面后退时的圆角。
  static const double recedeRadius = 28;

  /// 被覆盖页面蒙层最大不透明度。
  static const double recedeDim = 0.16;

  static const Curve forwardCurve = Curves.easeOutQuart;
  static const Curve reverseCurve = Curves.easeInOutCubic;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 360);

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _recede;

  static Widget? _recede(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    final Widget? slid = CupertinoPageTransition.delegatedTransition(
      context,
      animation,
      secondaryAnimation,
      allowSnapshotting,
      child,
    );
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return slid;
    }
    return RecedingPage(animation: secondaryAnimation, child: slid);
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _base.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// 「后退一层」的视觉：缩放 + 圆角 + 暮色蒙层。
///
/// 组件树结构恒定（无论 value 是否为 0 都是同一组 widget），只改参数，
/// 不会因为过渡开始/结束而重建子树、丢失页面状态。value 为 0 时不裁剪、
/// 不绘制蒙层，静止页面零额外开销。
class RecedingPage extends StatelessWidget {
  const RecedingPage({super.key, required this.animation, this.child});

  final Animation<double> animation;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final Curve curve = animation.status == AnimationStatus.reverse
            ? MiruPageTransitionsBuilder.reverseCurve
            : MiruPageTransitionsBuilder.forwardCurve;
        final double t = curve.transform(animation.value.clamp(0.0, 1.0));
        final double scale =
            1 - (1 - MiruPageTransitionsBuilder.recedeScale) * t;
        final double radius = MiruPageTransitionsBuilder.recedeRadius * t;
        return Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: t > 0 ? Clip.antiAlias : Clip.none,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                color: Colors.black.withValues(
                  alpha: MiruPageTransitionsBuilder.recedeDim * t,
                ),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
