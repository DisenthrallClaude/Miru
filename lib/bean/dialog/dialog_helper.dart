import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/frosted_surface.dart';
import 'package:kazumi/utils/theme.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/utils/constants.dart';

// A simple dialog helper class to show dialogs and toasts based on flutter native implementation (replace flutter_smart_dialog)
// flutter_smart_dialog use overlays and self-managed route stack to show dialogs.
// It's powerful but can't behave like the default showDialog, e.g. the lack of mask animation. the lack of snackbar.
// Use the implementation should be careful, because shared route stack with the whole app, it may cause some unexpected behaviors.
// Don't use it in double PopScope widget.
class KazumiDialog {
  /// The global observer that tracks contexts across the application
  static final KazumiDialogObserver observer = KazumiDialogObserver();

  KazumiDialog._internal();

  static Future<T?> show<T>({
    BuildContext? context,
    bool? clickMaskDismiss,
    VoidCallback? onDismiss,
    required WidgetBuilder builder,
  }) async {
    final ctx =
        context ?? rootNavigatorKey.currentContext ?? observer.currentContext;
    if (ctx != null && ctx.mounted) {
      try {
        final result = await showDialog<T>(
          context: ctx,
          useRootNavigator: true,
          barrierDismissible: clickMaskDismiss ?? true,
          // 弹窗出现时把背后页面整体模糊，做出 iOS 的玻璃层次。
          // 在这里统一处理，所有 KazumiDialog.show 调用点无需改动。
          barrierColor: Colors.black.withValues(alpha: 0.28),
          builder: (context) => _BlurredDialogBackdrop(child: builder(context)),
          routeSettings: const RouteSettings(name: 'KazumiDialog'),
        );
        onDismiss?.call();
        return result;
      } catch (e) {
        debugPrint('Kazumi Dialog Error: Failed to show dialog: $e');
        return null;
      }
    } else {
      debugPrint(
          'Kazumi Dialog Error: No context available to show the dialog');
      return null;
    }
  }

  static void showToast({
    required String message,
    BuildContext? context,
    bool showActionButton = false,
    String? actionLabel,
    Function()? onActionPressed,
    Duration duration = const Duration(seconds: 2),
  }) {
    final messenger = _resolveScaffoldMessenger(context);
    final toastContext = _resolveToastContext(context);
    if (messenger != null && toastContext != null && toastContext.mounted) {
      try {
        messenger
          ..removeCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              behavior: SnackBarBehavior.floating,
              width: MediaQuery.sizeOf(toastContext).width >
                      LayoutBreakpoint.medium['width']!
                  ? 600
                  : null,
              duration: duration,
              persist: false,
              action: showActionButton
                  ? SnackBarAction(
                      label: actionLabel ?? 'Dismiss',
                      onPressed: () {
                        onActionPressed?.call();
                        messenger.hideCurrentSnackBar();
                      },
                    )
                  : null,
            ),
          );
      } catch (e) {
        debugPrint('Kazumi Dialog Error: Failed to show toast: $e');
      }
    } else {
      debugPrint(
          'Kazumi Dialog Error: No ScaffoldMessenger available to show Toast');
    }
  }

  static Future<void> showLoading({
    BuildContext? context,
    String? msg,
    bool barrierDismissible = false,
    Function()? onDismiss,
  }) async {
    final ctx =
        context ?? rootNavigatorKey.currentContext ?? observer.currentContext;
    if (ctx != null && ctx.mounted) {
      try {
        await showDialog(
          context: ctx,
          useRootNavigator: true,
          barrierDismissible: barrierDismissible,
          builder: (BuildContext context) {
            return Center(
              child: Card(
                // 极简：去投影，靠表面色阶与细描边区分层次
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                shape: const RoundedRectangleBorder(borderRadius: Radii.brXl),
                child: Padding(
                  padding: const EdgeInsets.all(Space.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: Space.lg),
                      Text(
                        msg ?? 'Loading...',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          routeSettings: const RouteSettings(name: 'KazumiDialog'),
        );
        onDismiss?.call();
      } catch (e) {
        debugPrint('Kazumi Dialog Error: Failed to show loading dialog: $e');
      }
    } else {
      debugPrint(
          'Kazumi Dialog Error: No context available to show the loading dialog');
    }
  }

  static Future<T?> showBottomSheet<T>({
    BuildContext? context,
    required WidgetBuilder builder,
    Color? backgroundColor,
    double? elevation,
    ShapeBorder? shape,
    Clip? clipBehavior,
    BoxConstraints? constraints,
    Color? barrierColor,
    bool isScrollControlled = false,
    bool useRootNavigator = true,
    bool isDismissible = true,
    bool enableDrag = true,
    RouteSettings? routeSettings,
    AnimationController? transitionAnimationController,
    Offset? anchorPoint,
    bool useSafeArea = false,
  }) async {
    // Use provided context first, then root context, then fallback to current context
    final ctx = context ??
        rootNavigatorKey.currentContext ??
        observer.rootContext ??
        observer.currentContext;
    if (ctx != null && ctx.mounted) {
      try {
        final result = await showModalBottomSheet<T>(
          context: ctx,
          // 统一玻璃化：底色交给玻璃层，因此这里强制透明。
          // 调用方传入的 backgroundColor 会作为玻璃的色调参考。
          builder: (context) => _GlassSheet(child: builder(context)),
          backgroundColor: Colors.transparent,
          elevation: elevation,
          shape: shape,
          clipBehavior: clipBehavior,
          constraints: constraints,
          barrierColor: barrierColor,
          isScrollControlled: isScrollControlled,
          useRootNavigator: useRootNavigator,
          isDismissible: isDismissible,
          enableDrag: enableDrag,
          routeSettings:
              routeSettings ?? const RouteSettings(name: 'KazumiBottomSheet'),
          transitionAnimationController: transitionAnimationController,
          anchorPoint: anchorPoint,
          useSafeArea: useSafeArea,
        );
        return result;
      } catch (e) {
        debugPrint('Kazumi Dialog Error: Failed to show bottom sheet: $e');
        return null;
      }
    } else {
      debugPrint(
          'Kazumi Dialog Error: No context available to show the bottom sheet');
      return null;
    }
  }

  // 在存在返回值时弹出并附带返回值
  static void dismiss<T>({T? popWith}) {
    if (observer.hasKazumiDialog && observer.kazumiDialogContext != null) {
      try {
        Navigator.of(observer.kazumiDialogContext!).pop(popWith);
      } catch (e) {
        debugPrint('Kazumi Dialog Error: Failed to dismiss dialog: $e');
      }
    } else {
      debugPrint('Kazumi Dialog Debug: No active KazumiDialog to dismiss');
    }
  }

  /// Shows a non-dismissible timed success dialog with a linear progress
  /// countdown, then auto-dismisses when the countdown completes.
  ///
  /// The caller is responsible for dismissing any currently-open dialog
  /// BEFORE calling this method.
  ///
  /// [onComplete] is invoked after the dialog route finishes.
  static void showTimedSuccessDialog({
    required String title,
    required String message,
    required VoidCallback onComplete,
    Duration duration = const Duration(seconds: 3),
  }) {
    KazumiDialog.show<bool>(
      clickMaskDismiss: false,
      builder: (context) => _TimedSuccessDialog(
        title: title,
        message: message,
        duration: duration,
      ),
    ).then((completed) {
      if (completed == true) {
        onComplete();
      }
    });
  }

  static ScaffoldMessengerState? _resolveScaffoldMessenger(
    BuildContext? context,
  ) {
    if (context != null && context.mounted) {
      final scopedMessenger = ScaffoldMessenger.maybeOf(context);
      if (scopedMessenger != null) {
        return scopedMessenger;
      }
    }
    return rootScaffoldMessengerKey.currentState;
  }

  static BuildContext? _resolveToastContext(BuildContext? context) {
    if (context != null && context.mounted) {
      return context;
    }
    final messengerContext = rootScaffoldMessengerKey.currentContext;
    if (messengerContext != null && messengerContext.mounted) {
      return messengerContext;
    }
    return observer.scaffoldContext;
  }
}

class _TimedSuccessDialog extends StatelessWidget {
  const _TimedSuccessDialog({
    required this.title,
    required this.message,
    required this.duration,
  });

  final String title;
  final String message;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_rounded,
                  size: 32,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: duration,
                onEnd: () => KazumiDialog.dismiss(popWith: true),
                builder: (context, value, _) =>
                    LinearProgressIndicator(value: value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Navigator observer to track contexts and dialog routes
class KazumiDialogObserver extends NavigatorObserver {
  /// List of active dialog routes
  final List<Route<dynamic>> _kazumiDialogRoutes = [];
  bool _snackBarClearScheduled = false;

  /// The most recent context from any MaterialPageRoute or PopupRoute
  BuildContext? _currentContext;

  /// The most recent context from any route containing a Scaffold
  BuildContext? _scaffoldContext;

  /// The root context of the app (for bottom sheets to cover the entire app)
  BuildContext? _rootContext;

  BuildContext? get currentContext => _currentContext;

  BuildContext? get scaffoldContext => _scaffoldContext ?? _currentContext;

  /// Get the root context for bottom sheets, fallback to scaffold context, then current context
  BuildContext? get rootContext =>
      _rootContext ?? _scaffoldContext ?? _currentContext;

  bool get hasKazumiDialog => _kazumiDialogRoutes.isNotEmpty;

  BuildContext? get kazumiDialogContext => _kazumiDialogRoutes.isNotEmpty
      ? _kazumiDialogRoutes.last.navigator?.context
      : null;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (_isKazumiDialogRoute(route)) {
      _kazumiDialogRoutes.add(route);
    }
    if (route.navigator?.context != null) {
      _updateContexts(route.navigator!.context, route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _scheduleSnackBarClear();
    if (_isKazumiDialogRoute(route)) {
      _kazumiDialogRoutes.remove(route);
    }
    if (previousRoute?.navigator?.context != null) {
      _updateContexts(previousRoute!.navigator!.context, previousRoute);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _scheduleSnackBarClear();
    if (_isKazumiDialogRoute(oldRoute!)) {
      _kazumiDialogRoutes.remove(oldRoute);
    }
    if (_isKazumiDialogRoute(newRoute!)) {
      _kazumiDialogRoutes.add(newRoute);
    }
    if (newRoute.navigator?.context != null) {
      _updateContexts(newRoute.navigator!.context, newRoute);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _scheduleSnackBarClear();

    if (_isKazumiDialogRoute(route)) {
      _kazumiDialogRoutes.remove(route);
    }

    if (previousRoute?.navigator?.context != null) {
      _updateContexts(previousRoute!.navigator!.context, previousRoute);
    }
  }

  void _updateContexts(BuildContext context, Route<dynamic> route) {
    _currentContext = context;
    if (_hasScaffold(context)) {
      _scaffoldContext = context;
      // Always update root context with scaffold contexts to ensure we have the most recent one
      // This helps ensure bottom sheets appear at the app level
      _rootContext = context;
    }
  }

  bool _hasScaffold(BuildContext context) {
    return Scaffold.maybeOf(context) != null;
  }

  bool _isKazumiDialogRoute(Route<dynamic> route) {
    return route.settings.name == 'KazumiDialog' ||
        route.settings.name == 'KazumiBottomSheet';
  }

  void _scheduleSnackBarClear() {
    if (_snackBarClearScheduled) return;
    _snackBarClearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snackBarClearScheduled = false;
      // Route observer callbacks run while Navigator is reconciling routes.
      // Clearing the root messenger after the frame avoids mutating UI state
      // in the middle of that reconciliation.
      rootScaffoldMessengerKey.currentState?.removeCurrentSnackBar();
    });
  }
}

/// 给对话框加一层整屏背景模糊。
///
/// `showDialog` 本身只有一层半透明遮罩，没有模糊；这里在遮罩之上补一层
/// `BackdropFilter`，让背后的页面化开，从而与导航条的液态玻璃观感一致。
/// 模糊层不拦截手势，点击穿透到遮罩以保留「点外部关闭」的行为。
class _BlurredDialogBackdrop extends StatelessWidget {
  const _BlurredDialogBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: Frost.scrimBlur,
                sigmaY: Frost.scrimBlur,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 把 BottomSheet 内容放到液态玻璃之上。
///
/// 在 `KazumiDialog.showBottomSheet` 内统一包裹，所有调用点无需改动。
/// 顶部圆角与 `bottomSheetTheme.shape` 保持一致。
class _GlassSheet extends StatelessWidget {
  const _GlassSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FrostedSurface(
      borderRadius: Radii.sheetTop,
      child: child,
    );
  }
}
