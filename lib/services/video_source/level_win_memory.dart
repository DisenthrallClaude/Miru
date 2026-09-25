import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// v1.7.0（P1-3）：按 host 记住解析竞速的胜出层级。
///
/// 波次延迟（0/600ms/1500ms）对所有站点一视同仁的代价：
/// - 需要 JS 的站永远无法快解，却每次都白等 1.5s 才启动 WebView；
/// - 云端能解的站每次白等 600ms。
///
/// 记住每个 host 最近 [windowSize] 次的胜出层级（cache/fast/cloud/
/// webview）：某 host 连续 [windowSize] 次都是同一层级胜出时，下一次
/// 解析把该层级的波次延迟设为 0（与快解同时起跑）。
///
/// 持久化：JSON 文件（与 road_health 同款 tmp+rename 原子写），
/// [ttl] 内有效，最多 [maxEntries] 条 host。所有方法不抛出。
class LevelWinMemory {
  LevelWinMemory._();

  static final LevelWinMemory instance = LevelWinMemory._();

  static const String _fileName = 'resolve_level_hints.json';

  /// 记忆有效期：站点的解析结构变化后自然过期回落。
  static const Duration ttl = Duration(days: 7);

  /// 判定窗口：连续 N 次同层胜出才提前该层起跑（防单次抖动误判）。
  static const int windowSize = 3;

  /// 最多记忆的 host 数（FIFO 淘汰）。
  static const int maxEntries = 256;

  final Map<String, List<String>> _levels = {};
  final Map<String, int> _lastAt = {};
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
          data.forEach((host, value) {
            if (value is Map<String, dynamic>) {
              final at = (value['at'] as num?)?.toInt() ?? 0;
              if (now - at > ttl.inMilliseconds) return;
              final levels = (value['levels'] as List?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  const <String>[];
              if (levels.isNotEmpty) {
                _levels[host] = levels;
                _lastAt[host] = at;
              }
            }
          });
        }
      }
    } catch (e) {
      _loadFuture = null;
      MiruLogger().d('LevelWinMemory: load failed', error: e);
    }
  }

  /// 该 URL 的 host 是否有「连续 N 次同层胜出」的提前起跑建议。
  /// 返回 'cloud' / 'webview'；无建议返回 null。
  Future<String?> dominantLevelFor(String url) async {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return null;
    await _ensureLoaded();
    final levels = _levels[host];
    if (levels == null || levels.length < windowSize) return null;
    // 最近 windowSize 次全部同层。
    final recent = levels.sublist(levels.length - windowSize);
    final first = recent.first;
    if (recent.every((l) => l == first)) {
      // 只有慢层级值得提前（fast 本来就是 t=0；cache 是第 1 级不走竞速）。
      if (first == 'cloud' || first == 'webview') return first;
    }
    return null;
  }

  /// 记一次胜出（§5 首帧钩子调用：host + 胜出层级）。
  Future<void> recordWin(String? host, String? level) async {
    if (host == null || host.isEmpty) return;
    if (level == null || level.isEmpty) return;
    if (!_validLevels.contains(level)) return;
    await _ensureLoaded();
    final levels = _levels.putIfAbsent(host, () => []);
    levels.add(level);
    // 只保留最近 windowSize 次（判定窗口即全部历史）。
    if (levels.length > windowSize) {
      levels.removeRange(0, levels.length - windowSize);
    }
    _lastAt[host] = DateTime.now().millisecondsSinceEpoch;
    // FIFO 淘汰（按最后记录时间最旧者）。
    while (_levels.length > maxEntries) {
      String? oldest;
      var oldestAt = -1;
      _lastAt.forEach((h, at) {
        if (oldest == null || at < oldestAt) {
          oldest = h;
          oldestAt = at;
        }
      });
      if (oldest == null) break;
      _levels.remove(oldest);
      _lastAt.remove(oldest);
    }
    _dirty = true;
    unawaited(_flush());
  }

  static const List<String> _validLevels = ['cache', 'fast', 'cloud', 'webview'];

  Future<void> _flush() async {
    final file = _file;
    if (file == null || !_dirty) return;
    _dirty = false;
    try {
      final payload = {
        for (final entry in _levels.entries)
          entry.key: {
            'levels': entry.value,
            'at': _lastAt[entry.key] ?? 0,
          },
      };
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json.encode(payload), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      _dirty = true;
      MiruLogger().d('LevelWinMemory: flush failed', error: e);
    }
  }

  /// 测试用：清空记忆。
  Future<void> clearForTest() async {
    _levels.clear();
    _lastAt.clear();
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
