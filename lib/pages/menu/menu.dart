import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/bean/widget/frosted_surface.dart';
import 'package:kazumi/bean/widget/liquid_glass_indicator.dart';
import 'package:kazumi/utils/theme.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/router.dart';

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
      return;
    }
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
      KazumiDialog.showToast(message: '再按一次退出应用', context: context);
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
      // 内容延伸到导航条之下，配合毛玻璃形成 iOS 式的材质层次
      extendBody: true,
      body: _outlet(context, bottomInset: _navBarHeight),
      bottomNavigationBar: FrostedBar(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 玻璃滑块铺在页签之下，IgnorePointer 保证不抢手势
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
            NavigationBar(
              height: _navBarHeight,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
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
          ],
        ),
      ),
    );
  }

  Widget _sideMenu(BuildContext context, int selectedIndex) {
    const borderRadius = BorderRadius.only(
      topLeft: Radius.circular(Radii.lg),
      bottomLeft: Radius.circular(Radii.lg),
    );
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      body: Row(
        children: [
          EmbeddedNativeControlArea(
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
          Expanded(child: _outlet(context, borderRadius: borderRadius)),
        ],
      ),
    );
  }
}
