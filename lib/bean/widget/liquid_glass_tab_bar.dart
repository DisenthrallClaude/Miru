import 'package:flutter/material.dart';
import 'package:miru/bean/widget/liquid_glass_indicator.dart';

/// 带液态玻璃选中罩的 TabBar。
///
/// 玻璃块跟随 [controller] 的滑动进度实时移动（跟手），
/// 松手后由 TabController 的动画收敛到目标页签。
/// TabBar 自身的指示器与水波纹已在主题里关掉，这里只叠一层玻璃。
///
/// 用法与 `TabBar` 一致，替换即可，不改变任何交互逻辑。
class LiquidGlassTabBar extends StatelessWidget implements PreferredSizeWidget {
  const LiquidGlassTabBar({
    super.key,
    required this.controller,
    required this.tabs,
    this.isScrollable = false,
    this.indicatorHeight = 38,
    this.widthFactor = 0.84,
  });

  final TabController controller;
  final List<Widget> tabs;
  final bool isScrollable;
  final double indicatorHeight;
  final double widthFactor;

  @override
  Size get preferredSize => Size.fromHeight(kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    final bar = TabBar(
      controller: controller,
      tabs: tabs,
      isScrollable: isScrollable,
      indicator: const BoxDecoration(),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    );

    // 可滚动的 TabBar 每个页签宽度不等，玻璃块无法用「均分槽位」定位，
    // 这种情况直接退回普通 TabBar，避免错位。
    if (isScrollable) return bar;

    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 0,
          right: 0,
          height: indicatorHeight,
          child: AnimatedBuilder(
            animation: controller.animation ?? controller,
            builder: (context, _) {
              // animation.value 在滑动中是连续值，正好用来跟手
              final pos = controller.animation?.value ?? controller.index.toDouble();
              return LiquidGlassIndicator(
                index: controller.index,
                count: tabs.length,
                drivenPosition: pos,
                height: indicatorHeight,
                widthFactor: widthFactor,
              );
            },
          ),
        ),
        bar,
      ],
    );
  }
}
