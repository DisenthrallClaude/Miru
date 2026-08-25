import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// 单个规则源的长期健康档案。
class PluginHealthRecord {
  PluginHealthRecord({
    this.successCount = 0,
    this.failureCount = 0,
    this.consecutiveFailures = 0,
    this.lastSuccessAt = 0,
    this.lastFailureAt = 0,
  });

  factory PluginHealthRecord.fromJson(Map<String, dynamic> json) {
    return PluginHealthRecord(
      successCount: (json['successCount'] as num?)?.toInt() ?? 0,
      failureCount: (json['failureCount'] as num?)?.toInt() ?? 0,
      consecutiveFailures:
          (json['consecutiveFailures'] as num?)?.toInt() ?? 0,
      lastSuccessAt: (json['lastSuccessAt'] as num?)?.toInt() ?? 0,
      lastFailureAt: (json['lastFailureAt'] as num?)?.toInt() ?? 0,
    );
  }

  int successCount;
  int failureCount;
  int consecutiveFailures;
  int lastSuccessAt;
  int lastFailureAt;

  Map<String, dynamic> toJson() => {
        'successCount': successCount,
        'failureCount': failureCount,
        'consecutiveFailures': consecutiveFailures,
        'lastSuccessAt': lastSuccessAt,
        'lastFailureAt': lastFailureAt,
      };
}

/// 规则源健康度追踪器。
///
/// 与 [PluginValidityTracker] 的区别：那个只记录「本次启动内搜索成功过」，
/// 这里做**跨启动的持久化**统计（成功/失败次数、连续失败），供选源界面
/// 把长期不可用的源排到后面，避免用户反复踩坑。
///
/// 所有方法都不抛出：健康度是锦上添花的信号，任何读写失败都只记日志，
/// 绝不能影响解析或搜索主链路。
class PluginHealthTracker {
  PluginHealthTracker._();

  static final PluginHealthTracker instance = PluginHealthTracker._();

  static const String _fileName = 'plugin_health.json';

  /// 连续失败达到该值视为「近期不稳定」。
  static const int _unreliableThreshold = 3;

  final Map<String, PluginHealthRecord> _records = {};
  Future<void>? _loadFuture;
  Future<void>? _saveQueue;
  bool _loaded = false;

  Future<void> _ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final file = await _healthFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded =
            jsonDecode(content) as Map<String, dynamic>? ?? const {};
        final plugins = decoded['plugins'] as Map<String, dynamic>? ?? const {};
        plugins.forEach((name, raw) {
          if (raw is Map<String, dynamic>) {
            _records[name] = PluginHealthRecord.fromJson(raw);
          } else if (raw is Map) {
            _records[name] =
                PluginHealthRecord.fromJson(Map<String, dynamic>.from(raw));
          }
        });
      }
    } catch (error, stackTrace) {
      // 档案损坏时从空开始重建，不影响功能。
      MiruLogger().w('[PluginHealth] failed to load health records',
          error: error, stackTrace: stackTrace);
    } finally {
      _loaded = true;
    }
  }

  /// 记录一次成功的交互（搜索出结果 / 视频解析成功）。
  Future<void> recordSuccess(String pluginName) async {
    await _record(pluginName, (record) {
      record.successCount++;
      record.consecutiveFailures = 0;
      record.lastSuccessAt = DateTime.now().millisecondsSinceEpoch;
    });
  }

  /// 记录一次失败（搜索报错 / 解析超时）。「没有结果」不算失败。
  Future<void> recordFailure(String pluginName) async {
    await _record(pluginName, (record) {
      record.failureCount++;
      record.consecutiveFailures++;
      record.lastFailureAt = DateTime.now().millisecondsSinceEpoch;
    });
  }

  Future<void> _record(
    String pluginName,
    void Function(PluginHealthRecord record) mutate,
  ) async {
    try {
      await _ensureLoaded();
      final record = _records.putIfAbsent(pluginName, PluginHealthRecord.new);
      mutate(record);
      await _persist();
    } catch (error, stackTrace) {
      MiruLogger().w('[PluginHealth] failed to record for $pluginName',
          error: error, stackTrace: stackTrace);
    }
  }

  /// 该源近期是否可靠。无记录的新源默认可靠——
  /// 健康度只能惩罚有据可查的惯犯，不能冷启动歧视新源。
  Future<bool> isReliable(String pluginName) async {
    await _ensureLoaded();
    return _isReliableFromRecord(_records[pluginName]);
  }

  /// 同步版判断：数据未加载完时按可靠处理。
  /// 仅供构建排序键这类「宁可退化也不等待」的场景使用。
  bool isReliableSync(String pluginName) {
    if (!_loaded) return true;
    return _isReliableFromRecord(_records[pluginName]);
  }

  bool _isReliableFromRecord(PluginHealthRecord? record) {
    if (record == null) return true;
    if (record.consecutiveFailures < _unreliableThreshold) return true;
    // 连续失败很多，但期间有过新近成功（例如用户手动重试成功）：以成功为准。
    if (record.lastSuccessAt >= record.lastFailureAt) return true;
    return false;
  }

  Future<File> _healthFile() async {
    // 与插件 Cookie 存储同目录策略：应用支持目录下的独立文件。
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> _persist() async {
    // 串行化写入，避免并发覆盖。
    // 局部变量承接可空字段：Dart 的类型提升对实例字段无效。
    final Future<void>? prior = _saveQueue;
    _saveQueue = (prior ?? Future<void>.value()).whenComplete(() async {
      try {
        final file = await _healthFile();
        final payload = {
          'version': 1,
          'plugins': {
            for (final entry in _records.entries) entry.key: entry.value.toJson(),
          },
        };
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(payload), flush: true);
        await tmp.rename(file.path);
      } catch (error, stackTrace) {
        MiruLogger().w('[PluginHealth] failed to persist health records',
            error: error, stackTrace: stackTrace);
      }
    });
    await _saveQueue;
  }
}
