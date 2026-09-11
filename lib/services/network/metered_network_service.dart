import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:miru/services/logging/logger.dart';

/// Tracks whether the active link is cellular data rather than WLAN / LAN.
class MeteredNetworkService {
  MeteredNetworkService._();

  static final ValueNotifier<bool> _metered = ValueNotifier<bool>(false);
  static StreamSubscription<List<ConnectivityResult>>? _subscription;
  static int _revision = 0;
  static bool _initialized = false;
  static _LifecycleObserver? _lifecycleObserver;

  static bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isMetered => _metered.value;

  static ValueListenable<bool> get listenable => _metered;

  /// 启动订阅并挂上前后台生命周期守卫（幂等）。
  ///
  /// app 后台期间发生的网络切换不会重放给已建立的订阅，回到前台后
  /// isMetered 将保持陈旧——移动数据下 1.5GB demuxer 缓存与
  /// LocalMediaProxy 预取会继续消耗流量。生命周期守卫在 resumed 时
  /// 调用 [refresh] 重订阅并显式读取当前网络类型。
  /// （同步自上游 Kazumi 22f9ee1；Miru 侧把 resume 钩子内聚到本服务，
  /// 调用方 main.dart 的 `init()` 入口无需变更。）
  static void init() {
    if (!_supported || _initialized) {
      return;
    }
    _initialized = true;
    _lifecycleObserver = _LifecycleObserver();
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
    unawaited(refresh());
  }

  /// 重订阅网络事件流并显式读取当前网络类型。
  ///
  /// revision 计数防止并发调用的过期结果互相覆盖；首读带 3s 超时，
  /// 失败时保留上次状态。
  static Future<void> refresh() async {
    if (!_supported) return;
    final revision = ++_revision;
    try {
      // 重订阅以追回后台期间丢失的网络变更（事件流不重放当前态）。
      final previous = _subscription;
      _subscription = null;
      await previous?.cancel();
      if (revision != _revision) return;
      _subscription = Connectivity().onConnectivityChanged.listen(
        (results) {
          _revision++;
          _apply(results);
        },
        onError: (Object error) {
          MiruLogger().w('Network: 网络类型监听中断 $error');
        },
      );
      final results = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 3));
      // 丢弃被后续 refresh 或网络事件取代的过期读取。
      if (revision == _revision) {
        _apply(results);
      }
    } catch (error) {
      MiruLogger().w('Network: 读取网络类型失败，保留上次状态 $error');
    }
  }

  static void _apply(List<ConnectivityResult> results) {
    final metered = _isMetered(results);
    if (metered == null || metered == _metered.value) {
      return;
    }
    MiruLogger()
        .i(metered ? 'Network: 切换到移动数据网络' : 'Network: 切换到 WLAN / 局域网');
    _metered.value = metered;
  }

  // WLAN wins during handovers; unknown transports retain the last known state.
  static bool? _isMetered(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return false;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return true;
    }
    return null;
  }

  /// 测试专用：清空全部静态状态并取消订阅/移除生命周期守卫。
  @visibleForTesting
  static Future<void> debugResetForTest() async {
    final previous = _subscription;
    _subscription = null;
    _revision++;
    await previous?.cancel();
    final observer = _lifecycleObserver;
    if (observer != null) {
      WidgetsBinding.instance.removeObserver(observer);
      _lifecycleObserver = null;
    }
    _initialized = false;
    _metered.value = false;
  }
}

/// 前后台生命周期守卫：resumed 时刷新计量网络状态，
/// 追回后台期间 wifi↔移动数据切换丢失的事件。
class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(MeteredNetworkService.refresh());
    }
  }
}
