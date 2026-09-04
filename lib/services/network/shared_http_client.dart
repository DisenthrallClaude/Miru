import 'dart:io';

/// 全局共享 HttpClient（阶段 0 / §1.6）。
///
/// 现状问题：_probe、FastVideoSourceResolver、LocalMediaProxy 各自
/// `HttpClient()` + 用完 `close(force: true)`——首帧前对同一 CDN 要做
/// 3 次 DNS + TCP + TLS 握手，连接复用完全为零。
///
/// 方案：进程级单例连接池。所有探测/快解/代理回源共用同一 client：
/// - `maxConnectionsPerHost = 6`：同 host 并发上限（探测并发 3 + 预取
///   并发 3 的场景足够）；
/// - `idleTimeout = 30s`：空闲连接保留半分钟，换集/二刷直接复用；
/// - `connectionTimeout = 5s`：连接阶段硬顶（黑洞主机不得挂到 OS 级
///   ~2 分钟）；
/// - UA 置 null：由调用方按会话显式设置（规则/解析/播放各会话的 UA
///   不尽相同，客户端层不能钉死）。
///
/// **取消语义**：绝不 close 整个客户端——按会话取消用
/// `HttpClientRequest.abort()` 或 `StreamSubscription.cancel()`，
/// 连接由 idleTimeout 自然回收。
class SharedHttpClient {
  SharedHttpClient._();

  /// 进程级共享实例。懒初始化字段故意不用 late/工厂模式，
  /// 保持对测试可替换（[disposeForTest]）。
  static HttpClient? _instance;

  static HttpClient get io {
    final existing = _instance;
    if (existing != null) {
      return existing;
    }
    return _instance = HttpClient()
      ..maxConnectionsPerHost = 6
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = const Duration(seconds: 5)
      ..autoUncompress = true
      ..userAgent = null; // 由调用方显式设置
  }

  /// 仅供测试：重置单例，避免测试间连接池状态串扰。
  static void disposeForTest() {
    _instance?.close(force: true);
    _instance = null;
  }
}
