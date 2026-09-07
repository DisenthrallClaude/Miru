import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/utils/theme.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Lets [RouteAware] pages learn they were covered or revealed again.
///
/// Restricted to [PageRoute] on purpose: dialogs and bottom sheets are
/// PopupRoutes, and sitting under one does not make a page hidden.
final rootRouteObserver = RouteObserver<PageRoute<void>>();

/// Tab 切换过场（B3）。
///
/// flutter_modular 的转场取「被推送路由（叶子）」的配置：四个 tab
/// 叶子模块原先显式 `TransitionType.none`，父路由上那份 70ms fade
/// 从未生效（死配置），实际是硬切。统一引用这里，让切 tab 真正有
/// 过渡——180ms（Motion.fast）淡入，与玻璃滑块的弹簧运动形成
/// 内容层的呼应，又不拖慢全 app 频率最高的切换。
final tabTransition = CustomTransition(
  duration: Motion.fast,
  transitionsBuilder: (context, animation, secondaryAnimation, child) {
    return FadeTransition(opacity: animation, child: child);
  },
);

/// 「双击当前 tab 回顶」的跨层通知通道（B2）。
///
/// shell 无法从外部直接驱动子页滚动：RouterOutlet 的每个子页是
/// 独立 ModalRoute，而 PrimaryScrollController 是按路由各建一份
/// （routes.dart 的 _ModalScopeState），shell 侧拿到的那份没有
/// 任何子页滚动视图挂载。因此用极简的静态单槽登记表：当前 tab
/// 页挂载时登记回顶回调、卸载时注销，shell 在点击当前 tab 时触发。
/// 切 tab 走 RouterOutlet.navigate 的整栈替换——任意时刻最多只有
/// 一个 tab 页存活，单槽即够且不会串台。
abstract final class TabScrollToTop {
  static VoidCallback? _handler;

  /// 当前 tab 页登记回顶回调（在 initState 调用）。
  static void register(VoidCallback handler) => _handler = handler;

  /// 卸载时注销。只注销自己（用 == 而非 identical：方法 tear-off
  /// 每次求值是新对象但同一实例上互相相等），避免误清后来者。
  static void unregister(VoidCallback handler) {
    if (_handler == handler) _handler = null;
  }

  /// shell 触发当前 tab 回顶；未接入的 tab（无登记者）静默忽略。
  static void request() => _handler?.call();
}
