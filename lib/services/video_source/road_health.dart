import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/shared_http_client.dart';
import 'package:path_provider/path_provider.dart';

/// 单条线路（road）的健康快照（阶段 3 / §3.3）。
class RoadHealth {
  const RoadHealth({
    required this.ok,
    required this.latencyMs,
    required this.probedAt,
  });

  /// 页面级可达性：对线路第一集 URL 发 GET，2xx/3xx 即 ok。
  final bool ok;

  /// 探测耗时（毫秒）。失败时为放弃前的耗时（超时=上限值）。
  final int latencyMs;

  /// 最近一次探测的本地时间戳（毫秒）。
  final int probedAt;

  factory RoadHealth.fromJson(Map<String, dynamic> json) {
    return RoadHealth(
      ok: json['ok'] == true,
      latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 0,
      probedAt: (json['probedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'latencyMs': latencyMs,
        'probedAt': probedAt,
      };

  /// 健康分（大者优先）：存活 > 快。死线路 0 分。
  int get score => ok ? 1000000 - latencyMs.clamp(0, 999999) : 0;
}

/// 线路健康探测与持久化（阶段 3 / §3.3）。
///
/// 目标：进播放页后台摸一遍线路（并发 4、单条 3s、总预算 4s），
/// 换线路弹层显示徽标、初始自动选路有据可依。探测是「页面级」的
/// ——拿线路第一集的播放页 URL 发 GET，能回 2xx/3xx 说明该线路的
/// 源站活着；死线路的直链解析必败，提前知道就能跳过。
///
/// 设计约束：
/// - 永不阻塞播放主链路（后台 fire-and-forget，调用方不 await）；
/// - 结果持久化（JSON，10min TTL），二次进页立即有徽标；
/// - 所有方法不抛出：健康信息是锦上添花，坏了只记日志。
class RoadHealthTracker {
  RoadHealthTracker._();

  static final RoadHealthTracker instance = RoadHealthTracker._();

  static const String _fileName = 'road_health.json';

  /// 探测结果有效期：超过后徽标降级为「未知」、不再参与自动选路。
  static const Duration resultTtl = Duration(minutes: 10);

  /// 单条线路探测超时（§3.3：3s）。
  static const Duration probeTimeout = Duration(seconds: 3);

  /// 并发（§3.3：4 路）。
  static const int concurrency = 4;

  /// 总预算（§3.3：4s——并发 4 时所有线路都应在预算内完成）。
  static const Duration totalBudget = Duration(seconds: 4);

  final Map<String, RoadHealth> _records = {};
  Future<void>? _loadFuture;
  Future<void>? _saveQueue;
  bool _loaded = false;
  bool _probing = false;

  Future<void> _ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final file = await _healthFile();
      if (await file.exists()) {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>?;
        final roads = decoded?['roads'] as Map<String, dynamic>? ?? const {};
        roads.forEach((key, raw) {
          if (raw is Map) {
            _records[key] =
                RoadHealth.fromJson(Map<String, dynamic>.from(raw));
          }
        });
      }
    } catch (error, stackTrace) {
      MiruLogger().w('[RoadHealth] load failed, starting empty',
          error: error, stackTrace: stackTrace);
    } finally {
      _loaded = true;
    }
  }

  Future<File> _healthFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> _persist() async {
    final Future<void>? prior = _saveQueue;
    _saveQueue = (prior ?? Future<void>.value()).whenComplete(() async {
      try {
        final file = await _healthFile();
        final payload = {
          'version': 1,
          'roads': {
            for (final entry in _records.entries) entry.key: entry.value.toJson(),
          },
        };
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(payload), flush: true);
        await tmp.rename(file.path);
      } catch (error, stackTrace) {
        MiruLogger().w('[RoadHealth] persist failed',
            error: error, stackTrace: stackTrace);
      }
    });
    return _saveQueue;
  }

  String _key(String pluginName, String roadName) =>
      '$pluginName::$roadName';

  /// 后台探测全部线路（fire-and-forget 入口；返回的 future 供测试用）。
  ///
  /// [roads] 的 data 取第一条非空 URL（该线路第 1 集播放页）；
  /// 空线路直接记 dead。已在探测中/结果新鲜时跳过（不重复打源站）。
  Future<void> probeAll(
    List<(String name, List<String> data)> roads,
    String pluginName,
  ) async {
    try {
      await _ensureLoaded();
      if (_probing) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final stale = <(String, List<String>)>[];
      for (final (name, data) in roads) {
        final record = _records[_key(pluginName, name)];
        final fresh = record != null &&
            now - record.probedAt < resultTtl.inMilliseconds;
        if (!fresh) stale.add((name, data));
      }
      if (stale.isEmpty) return;
      _probing = true;
      try {
        await _probeStale(stale, pluginName);
      } finally {
        _probing = false;
      }
    } catch (error, stackTrace) {
      MiruLogger().w('[RoadHealth] probeAll failed',
          error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _probeStale(
      List<(String, List<String>)> roads, String pluginName) async {
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= roads.length) return;
        final (name, data) = roads[i];
        final url = data.isNotEmpty ? data.first : '';
        final health = url.isEmpty
            ? RoadHealth(ok: false, latencyMs: 0,
                probedAt: DateTime.now().millisecondsSinceEpoch)
            : await _probeOne(url);
        _records[_key(pluginName, name)] = health;
      }
    }

    await Future.wait(
      List.generate(concurrency.clamp(1, roads.length), (_) => worker()),
    ).timeout(totalBudget, onTimeout: () {
      // 总预算兜底：超时的线路本次不更新（保持旧记录/未知）。
      MiruLogger().d('[RoadHealth] probe budget exhausted, partial update');
      return [];
    });
    await _persist();
  }

  /// 页面级探测：GET 线路第一集播放页，2xx/3xx = ok。
  /// 只读响应头即断开（drain 少量后 close），不下载正文。
  Future<RoadHealth> _probeOne(String url) async {
    final started = DateTime.now();
    var ok = false;
    try {
      final client = SharedHttpClient.io;
      final request =
          await client.getUrl(Uri.parse(url)).timeout(probeTimeout);
      request.headers.set('user-agent', _probeUserAgent);
      // HEAD 不少站返回 405；GET + 立刻断开同样只花一个 RTT。
      final response = await request.close().timeout(probeTimeout);
      ok = response.statusCode >= 200 && response.statusCode < 400;
      // 只取前几 KB 即断开：页面正文对健康判定无用。
      await response.drain<void>().timeout(probeTimeout).catchError((_) {});
    } catch (_) {
      ok = false;
    }
    return RoadHealth(
      ok: ok,
      latencyMs: DateTime.now().difference(started).inMilliseconds,
      probedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static const String _probeUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  /// 线路健康（新鲜期内），无记录/过期返回 null（徽标显示「未知」）。
  Future<RoadHealth?> healthOf(String pluginName, String roadName) async {
    await _ensureLoaded();
    return _healthOfSync(pluginName, roadName);
  }

  /// 同步版：数据未加载完时返回 null。
  RoadHealth? _healthOfSync(String pluginName, String roadName) {
    if (!_loaded) return null;
    final record = _records[_key(pluginName, roadName)];
    if (record == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch - record.probedAt;
    if (age > resultTtl.inMilliseconds) return null;
    return record;
  }

  /// 自动选路建议（§3.3）：健康分最高的线路下标；全部未知返回
  /// [fallback]（保持既有行为——默认第 0 条）。
  Future<int> bestRoadIndex(
    List<String> roadNames,
    String pluginName, {
    int fallback = 0,
  }) async {
    await _ensureLoaded();
    var best = fallback;
    var bestScore = -1;
    for (var i = 0; i < roadNames.length; i++) {
      final health = _healthOfSync(pluginName, roadNames[i]);
      if (health == null) continue;
      if (health.score > bestScore) {
        bestScore = health.score;
        best = i;
      }
    }
    return bestScore >= 0 ? best : fallback;
  }

  /// 供测试：清空内存与持久化记录。
  Future<void> resetForTest() async {
    _records.clear();
    _probing = false;
    try {
      final file = await _healthFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
