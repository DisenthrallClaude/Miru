import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter/services.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/widget/embedded_native_control_area.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/bean/widget/liquid_glass_indicator.dart';
import 'package:miru/bean/widget/liquid_glass_panel.dart';
import 'package:miru/utils/theme.dart';
import 'package:miru/navigation.dart';
import 'package:miru/pages/menu/route_visibility.dart';
import 'package:miru/pages/router.dart';

class ScaffoldMenu extends StatefulWidget {
  const ScaffoldMenu({super.key});

  @override
  State<ScaffoldMenu> createState() => _ScaffoldMenu();
}

class _ScaffoldMenu extends State<ScaffoldMenu> with RouteAware {
  final _outletKey = GlobalKey<RouterOutletState>();
  DateTime? _lastExitPromptAt;

  /// The shell sits at the bottom of the root stack and stays mounted while
  /// other pages cover it, so it publishes that state for its subtree.
  bool _isCovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      rootRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    rootRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => _setCovered(true);

  @override
  void didPopNext() => _setCovered(false);

  void _setCovered(bool value) {
    if (!mounted || _isCovered == value) {
      return;
    }
    setState(() => _isCovered = value);
  }

  void _selectDestination(int index) {
    _lastExitPromptAt = null;
    final currentIndex =
        menu.indexForPath(context.routeState(listen: false).uri.path);
    if (index == currentIndex) {
      // B2：双击当前 tab 回顶。子页滚动结构拿不到（见
      // TabScrollToTop 的说明），通过登记通道通知当前子页自己回顶。
      TabScrollToTop.request();
      return;
    }
    // B1：切 tab 触觉反馈——全 app 频率最高的操作，玻璃滑块的
    // 弹簧过冲配一次 selectionClick 手感才完整。
    HapticFeedback.selectionClick();
    _outletKey.currentState?.navigate('/tab${menu.getPath(index)}/');
  }

  void _handleSystemBack(BuildContext context) {
    if (_outletKey.currentState?.maybePop() ?? false) {
      _lastExitPromptAt = null;
      return;
    }

    final currentIndex =
        menu.indexForPath(context.routeState(listen: false).uri.path);
    if (currentIndex != 0) {
      _selectDestination(0);
      return;
    }

    final now = DateTime.now();
    final lastPromptAt = _lastExitPromptAt;
    if (lastPromptAt == null ||
        now.difference(lastPromptAt) > const Duration(seconds: 2)) {
      _lastExitPromptAt = now;
      MiruDialog.showToast(message: '再按一次退出应用', context: context);
      return;
    }

    _lastExitPromptAt = null;
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = menu.indexForPath(context.routeState().uri.path);
    return RouteVisibility(
      isCovered: _isCovered,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _handleSystemBack(context);
          }
        },
        child: OrientationBuilder(
          builder: (context, orientation) {
            return orientation == Orientation.portrait
                ? _bottomMenu(context, selectedIndex)
                : _sideMenu(context, selectedIndex);
          },
        ),
      ),
    );
  }

  /// 底部毛玻璃导航条的高度（不含系统手势区）。
  /// 需与 theme.dart 中 navigationBarTheme.height 保持一致；
  /// 取 70 是为了在「图标 + 常驻文字标签」下留出足够垂直空间，避免溢出。
  static const double _navBarHeight = 70;

  /// 玻璃滑块高度。要足够高才能完整包住「图标 + 文字」这一组。
  static const double _indicatorHeight = 54;

  Widget _outlet(
    BuildContext context, {
    BorderRadius? borderRadius,
    double bottomInset = 0,
  }) {
    Widget child = NotificationListener<NavigationNotification>(
      // A non-poppable outlet must not override the shell's PopScope state.
      onNotification: (notification) => !notification.canHandlePop,
      child: RouterOutlet(key: _outletKey),
    );

    // 内容层要延伸到毛玻璃导航条之下，因此把导航条高度并入
    // MediaQuery 的底部安全区，页面据此留白即可避免被遮挡。
    if (bottomInset > 0) {
      final mq = MediaQuery.of(context);
      child = MediaQuery(
        data: mq.copyWith(
          padding: mq.padding.copyWith(
            bottom: mq.padding.bottom + bottomInset,
          ),
        ),
        child: child,
      );
    }

    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius, child: child);
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }

  Widget _bottomMenu(BuildContext context, int selectedIndex) {
    return Scaffold(
      // 内容延伸到导航条之下，配合玻璃形成 iOS 式的材质层次
      extendBody: true,
      body: _outlet(context, bottomInset: _navBarHeight),
      // v1.6.4：悬浮液态玻璃 Dock——与开屏同源的真实折射玻璃
      //（ClipRRect + BackdropFilter(ImageFilter.shader)）：内容从
      // 玻璃下滚过时被弯折、rim 色散、顶部内侧高光。回退路径自动
      // 降级为毛玻璃。
      bottomNavigationBar: LiquidGlassDock(
        height: _navBarHeight,
        radius: 32,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 玻璃滑块铺在页签之下，IgnorePointer 保证不抢手势。
            //
            // v1.6.5 对齐修复：滑块的槽位必须与 NavigationBar 的页签
            // 严格同宽同域。M3 NavigationBar 的 Row 用 Expanded 把页签
            // 均分【整条宽度】（scaffold.dart / navigation_bar.dart 源码），
            // 之前 left:12/right:12 的内缩让滑块按 (宽-24)/4 分槽，
            // 首项中心偏右 9px、末项偏左 9px——「小球没落在文字中心」。
            // 现在 left:0/right:0 跨满 Dock 内宽，槽位与页签逐像素对齐。
            Positioned(
              left: 0,
              right: 0,
              top: (_navBarHeight - _indicatorHeight) / 2,
              height: _indicatorHeight,
              child: LiquidGlassIndicator(
                index: selectedIndex,
                count: 4,
                height: _indicatorHeight,
              ),
            ),
            // v1.6.5 垂直修复（含复审代理 A 发现的 top 回注问题）：
            // Scaffold 对 bottomNavigationBar 槽位本身已做
            // removePadding(removeTop: true, removeBottom: false)
            //（scaffold.dart:3163），而悬浮 Dock 又自行抬离手势区——
            // NavigationBar 内置 SafeArea 再消费一次 bottom inset 会把
            // 70px 页签行压扁。这里用【调用处 context】整体重建
            // MediaQuery（removePadding 按调用处求值——位于 Scaffold
            // 之上，ambient 仍含状态栏 top inset），若只剥 bottom 会把
            // top inset 重新注入：SafeArea 从顶部再吃 32px，行中心
            // 反向偏移比修复前更糟。因此四个方向全剥，NavigationBar
            // 恢复满高满宽，行中心与滑块中心（(70-54)/2+27=35）对齐。
            MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeTop: true,
              removeRight: true,
              removeBottom: true,
              child: NavigationBar(
                height: _navBarHeight,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                indicatorColor: Colors.transparent,
                destinations: const <Widget>[
                  NavigationDestination(
                    selectedIcon: Icon(Icons.auto_awesome_rounded),
                    icon: Icon(Icons.auto_awesome_outlined),
                    label: '推荐',
                  ),
                  NavigationDestination(
                    selectedIcon: Icon(Icons.calendar_today_rounded),
                    icon: Icon(Icons.calendar_today_outlined),
                    label: '时间表',
                  ),
                  NavigationDestination(
                    selectedIcon: Icon(Icons.bookmark_rounded),
                    icon: Icon(Icons.bookmark_border_rounded),
                    label: '追番',
                  ),
                  NavigationDestination(
                    selectedIcon: Icon(Icons.person_rounded),
                    icon: Icon(Icons.person_outline_rounded),
                    label: '我的',
                  ),
                ],
                selectedIndex: selectedIndex,
                onDestinationSelected: _selectDestination,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideMenu(BuildContext context, int selectedIndex) {
    // 内容窗格保持原有的左侧圆角，与侧栏玻璃面板形成「两块浮起的面板」。
    const contentBorderRadius = BorderRadius.only(
      topLeft: Radius.circular(Radii.lg),
      bottomLeft: Radius.circular(Radii.lg),
    );
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      body: Row(
        children: [
          EmbeddedNativeControlArea(
            // 宽屏侧栏：悬浮式液态玻璃面板。
            // 四周留出缝隙，玻璃的边缘高光与镜面渐变才可见；
            // 模糊采样的是身后的 surfaceContainer 底色，
            // 与右侧内容窗格形成材质层次。导航行为与选中态不变。
            child: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: FrostedSurface(
                borderRadius: Radii.brLg,
                border: Border.all(
                  color: scheme.outlineVariant,
                  width: 0.5,
                ),
                child: NavigationRail(
                  backgroundColor: Colors.transparent,
                  groupAlignment: 1,
                  leading: Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: IconButton.filledTonal(
                      onPressed: () => context.pushNamed('/search/'),
                      icon: const Icon(Icons.search_rounded),
                      style: IconButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                          borderRadius: Radii.brMd,
                        ),
                        padding: const EdgeInsets.all(Space.md),
                      ),
                    ),
                  ),
                  labelType: NavigationRailLabelType.selected,
                  destinations: const <NavigationRailDestination>[
                    NavigationRailDestination(
                      selectedIcon: Icon(Icons.auto_awesome_rounded),
                      icon: Icon(Icons.auto_awesome_outlined),
                      label: Text('推荐'),
                    ),
                    NavigationRailDestination(
                      selectedIcon: Icon(Icons.calendar_today_rounded),
                      icon: Icon(Icons.calendar_today_outlined),
                      label: Text('时间表'),
                    ),
                    NavigationRailDestination(
                      selectedIcon: Icon(Icons.bookmark_rounded),
                      icon: Icon(Icons.bookmark_border_rounded),
                      label: Text('追番'),
                    ),
                    NavigationRailDestination(
                      selectedIcon: Icon(Icons.person_rounded),
                      icon: Icon(Icons.person_outline_rounded),
                      label: Text('我的'),
                    ),
                  ],
                  selectedIndex: selectedIndex,
                  onDestinationSelected: _selectDestination,
                ),
              ),
            ),
          ),
          Expanded(child: _outlet(context, borderRadius: contentBorderRadius)),
        ],
      ),
    );
  }
}
