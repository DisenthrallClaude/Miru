import 'dart:async';

/// v1.6.3 启动闸门：液态玻璃欢迎页与后台初始化的协调器。
///
/// v1.6.2 及之前，InitPage 要等规则加载（_pluginInit）、下载记录复位等
/// 全部完成后才导航——首启动用户先看到一页空白的 LoadingWidget。
/// v1.6.3 起，首启动 / 开屏常显时先进液态玻璃欢迎页，初始化转后台：
///
/// * [InitPage] 完成 `Future.wait([...])` 后调用 [markPluginsReady]；
/// * [OnboardingPage] 在进入主界面前 `await pluginsReady`（带兜底超时），
///   保证规则控制器、下载控制器等就绪，避免与后台 init 竞态。
///
/// 闸门是进程级单次性的：一次 App 生命周期只开一次，重复调用安全。
class StartupGate {
  StartupGate._();

  static final Completer<void> _completer = Completer<void>();

  /// 等待首屏初始化完成（最多 [timeout]，超时按就绪处理并放行）。
  ///
  /// 超时兜底：极端慢机/IO 卡顿时也不能把用户挡在玻璃页里。
  static Future<void> pluginsReady({
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _completer.future.timeout(timeout, onTimeout: () {});
  }

  /// 标记初始化完成；幂等。
  static void markPluginsReady() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  /// 初始化是否已完成（用于决定要不要显示等待进度）。
  static bool get isReady => _completer.isCompleted;
}
