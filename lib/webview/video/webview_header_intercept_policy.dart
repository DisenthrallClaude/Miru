import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// v1.7.0（P1-2）：WebView `shouldInterceptRequest` 的按需开关。
///
/// 背景工单：shouldInterceptRequest 在 Android 上会**同步阻塞** WebView
/// 的 IO 线程等 Dart 回调返回——页面的每个 JS/XHR/分片请求都过一次
/// 平台通道，UI isolate 一忙所有请求排队，是 JS 站嗅探慢的主因之一。
/// v1.7.0 起默认关闭（onLoadResource 异步回调 + JS PerformanceObserver
/// 兜底），只有「嗅探成功但播放 403」的站点才重新打开（请求头必须
/// 从拦截层捕获的 host）。
///
/// 记忆形态：host → 最后记录时间（JSON 文件，[ttl] 内有效，
/// 最多 [maxEntries] 条，FIFO 淘汰）。所有方法不抛出。
class WebviewHeaderInterceptPolicy {
  WebviewHeaderInterceptPolicy._();

  static final WebviewHeaderInterceptPolicy instance =
      WebviewHeaderInterceptPolicy._();

  static const String _fileName = 'webview_intercept_hosts.json';

  /// 记忆有效期：一个月内出现过「嗅探成功但播放 403」的 host 继续
  /// 拦截；站点的防护策略变化后自然过期回落。
  static const Duration ttl = Duration(days: 30);

  /// 最多记忆的 host 数（防无限膨胀）。
  static const int maxEntries = 64;

  final Map<String, int> _hosts = {};
  Future<void>? _loadFuture;
  bool _dirty = false;

  File? _file;

  Future<void> _ensureLoaded() => _loadFuture ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/$_fileName');
      if (await _file!.exists()) {
        final data = json.decode(await _file!.readAsString());
        if (data is Map<String, dynamic>) {
          final now = DateTime.now().millisecondsSinceEpoch;
          data.forEach((host, at) {
            final ts = (at as num?)?.toInt() ?? 0;
            if (now - ts <= ttl.inMilliseconds) {
              _hosts[host] = ts;
            }
          });
        }
      }
    } catch (e) {
      // 坏文件/IO 错误：从空表开始（拦截是优化不是正确性依赖）。
      _loadFuture = null;
      MiruLogger().d('WebviewHeaderInterceptPolicy: load failed', error: e);
    }
  }

  /// 该 URL 的 host 是否需要开启请求头拦截。
  Future<bool> shouldIntercept(String url) async {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return false;
    await _ensureLoaded();
    return _hosts.containsKey(host);
  }

  /// 记一次「嗅探成功但播放失败」——该 host 的播放头需要从拦截层
  /// 捕获，下次嗅探开启 shouldInterceptRequest。
  Future<void> recordInterceptNeeded(String url) async {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return;
    await _ensureLoaded();
    _hosts[host] = DateTime.now().millisecondsSinceEpoch;
    // FIFO 淘汰最旧。
    while (_hosts.length > maxEntries) {
      final oldest = _hosts.entries
          .reduce((a, b) => a.value <= b.value ? a : b)
          .key;
      _hosts.remove(oldest);
    }
    _dirty = true;
    unawaited(_flush());
    MiruLogger().i('WebViewIntercept: enabled for $host (playback 403 after sniff)');
  }

  Future<void> _flush() async {
    final file = _file;
    if (file == null || !_dirty) return;
    _dirty = false;
    try {
      // 原子写（与 resolution_result_cache 同款：tmp + rename）。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json.encode(_hosts), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      _dirty = true;
      MiruLogger().d('WebviewHeaderInterceptPolicy: flush failed', error: e);
    }
  }

  /// 测试用：清空内存与磁盘记忆。
  Future<void> clearForTest() async {
    _hosts.clear();
    _dirty = false;
    _loadFuture = null;
    _file = null;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_fileName');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
