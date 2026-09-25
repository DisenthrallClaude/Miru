import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/webview/video/video_webview_controller.dart';

/// v1.7.0（P1-1）：进程级常驻 + 预热的无头 WebView 池。
///
/// 旧链路：每个播放页 new 一个 WebViewVideoSourceService，第一次走到
/// WebView 层才 init()（PlatformHeadlessInAppWebView.run()，Chromium
/// 冷启动 300~1500ms），退出播放页 dispose() 销毁——每进一次播放页都
/// 冷启动一次 Chromium。
///
/// 池语义：
/// - [acquire]：优先取空闲实例（已 init、已注入脚本）；没有则创建并
///   初始化（10s 硬超时，失败不残留）；
/// - [release]：unloadPage（about:blank）归还池，**不 dispose**——
///   脚本注入与 Chromium 进程都保留，下一次 acquire 零冷启动；
/// - [preheat]：预热一个空闲实例（应用首帧后延迟 3s / 进详情页时）；
/// - 内存吃紧（didHaveMemoryPressure）：释放全部空闲实例。
///
/// 池大小 1：追番场景同一时刻只有一个嗅探在跑；headless WebView 每个
/// 实例吃 50~80MB。下载路径不占池（独占新实例）。
class WebViewPool with WidgetsBindingObserver {
  WebViewPool._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final WebViewPool instance = WebViewPool._();

  /// 空闲实例上限。
  static const int maxIdle = 1;

  /// 实例初始化硬超时（与 WebViewVideoSourceService 的 10s 对齐：
  /// 挂起不得拖死借用方）。
  static const Duration initTimeout = Duration(seconds: 10);

  final List<VideoWebviewController> _idle = [];
  final Set<VideoWebviewController> _leased = {};

  /// 预热去重。
  Future<void>? _preheatFuture;

  /// 在途初始化（多个 acquire 并发时只创建一个实例）。
  Future<VideoWebviewController>? _creating;

  /// 当前空闲实例数（诊断用）。
  int get idleCount => _idle.length;

  /// 当前借出实例数（诊断用）。
  int get leasedCount => _leased.length;

  /// 借出一个已初始化的 WebView 控制器。
  ///
  /// 并发 acquire 时排队共享同一次创建（池满前不超额创建——
  /// 追番场景嗅探本身串行）。
  Future<VideoWebviewController> acquire() async {
    if (_idle.isNotEmpty) {
      final controller = _idle.removeLast();
      _leased.add(controller);
      return controller;
    }
    // 没有空闲实例：创建（去重共享在途创建）。
    final creating = _creating ??= _create();
    try {
      final controller = await creating;
      _leased.add(controller);
      return controller;
    } finally {
      if (identical(_creating, creating)) {
        _creating = null;
      }
    }
  }

  Future<VideoWebviewController> _create() async {
    final controller = VideoWebviewControllerFactory.getController();
    try {
      await controller.init().timeout(initTimeout);
    } catch (e) {
      // 初始化失败的实例绝不入池/出借（半初始化实例行为异常）。
      try {
        await controller.dispose();
      } catch (_) {}
      rethrow;
    }
    MiruLogger().d('WebViewPool: created and initialized a controller');
    return controller;
  }

  /// 归还实例：清空页面但不销毁（脚本注入与 Chromium 进程保留）。
  Future<void> release(VideoWebviewController controller) async {
    if (!_leased.remove(controller)) {
      // 非本池借出（防御）：直接销毁，不留无主实例。
      try {
        await controller.dispose();
      } catch (_) {}
      return;
    }
    try {
      await controller.unloadPage();
    } catch (e) {
      MiruLogger().d('WebViewPool: unloadPage failed on release', error: e);
    }
    if (_idle.length < maxIdle) {
      _idle.add(controller);
    } else {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  /// 预热：确保池里有一个空闲实例（幂等，失败静默——预热是优化）。
  Future<void> preheat() async {
    if (_idle.isNotEmpty || _creating != null) return;
    _preheatFuture ??= (() async {
      try {
        final controller = await acquire();
        await release(controller);
      } catch (e) {
        MiruLogger().d('WebViewPool: preheat failed', error: e);
      } finally {
        _preheatFuture = null;
      }
    })();
    return _preheatFuture;
  }

  /// 内存吃紧：释放全部空闲实例（借出中的实例由借用方归还时处置）。
  @override
  void didHaveMemoryPressure() {
    final idle = List<VideoWebviewController>.of(_idle);
    _idle.clear();
    for (final controller in idle) {
      unawaited(controller.dispose().catchError((Object e) {
        return Future<void>.value();
      }));
    }
    if (idle.isNotEmpty) {
      MiruLogger().i('WebViewPool: released ${idle.length} idle controller(s) on memory pressure');
    }
  }

  /// 进程收尾/测试：全部销毁。
  Future<void> disposeAll() async {
    final all = [..._idle, ..._leased];
    _idle.clear();
    _leased.clear();
    for (final controller in all) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }
}

/// v1.7.0（P1-1）：应用首帧后延迟 3s 空闲预热（init_page 挂接）。
///
/// 放在 WidgetsBinding 后台调度（scheduleTask idle）里，不与首页
/// 构建抢主线程；3s 延迟避开启动高峰。
void scheduleWebViewPoolPreheat() {
  Future<void>.delayed(const Duration(seconds: 3), () {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      unawaited(WebViewPool.instance.preheat());
    } else {
      // 帧管线忙：下一帧再试（一次性，不再无限顺延）。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        unawaited(WebViewPool.instance.preheat());
      });
    }
  });
}

@visibleForTesting
void debugResetWebViewPoolForTest() {
  // 仅暴露给测试做清理入口（disposeAll 的便捷别名）。
  unawaited(WebViewPool.instance.disposeAll());
}
