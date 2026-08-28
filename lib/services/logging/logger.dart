import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

const Symbol _forceLogKey = #_forceLog;

String _singleLineLogText(Object? value) {
  return value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

class MiruLogFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    final forceLog = Zone.current[_forceLogKey] as bool? ?? false;
    if (forceLog) {
      return true;
    }
    return event.level.index >= Logger.level.index;
  }
}

class MiruLogPrinter extends LogPrinter {
  static const int _stackFrameLimit = 8;

  @override
  List<String> log(LogEvent event) {
    final time = _formatTime(event.time);
    final level = _colorizeLevel(event.level);
    final message = _singleLineLogText(_stringifyMessage(event.message));
    final error =
        event.error == null ? '' : ' | ${_singleLineLogText(event.error)}';
    final lines = <String>['$time $level $message$error'];

    // error 级以上且调用方提供了堆栈时输出（fatal 一直输出，
    // 兼容旧的无堆栈 error 调用不至于噪声爆炸）。
    if (event.level == Level.fatal) {
      lines.addAll(_formatStackTrace(event.stackTrace ?? StackTrace.current));
    } else if (event.level == Level.error && event.stackTrace != null) {
      lines.addAll(_formatStackTrace(event.stackTrace!));
    }

    return lines;
  }

  String _colorizeLevel(Level level) {
    const reset = '\x1B[0m';
    final color = switch (level) {
      Level.trace => '\x1B[90m',
      Level.debug => '\x1B[36m',
      Level.info => '\x1B[32m',
      Level.warning => '\x1B[33m',
      Level.error => '\x1B[31m',
      Level.fatal => '\x1B[35m',
      _ => '',
    };
    final name = level.name.toUpperCase().padRight(7);
    return '$color$name$reset';
  }

  String _formatTime(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final milliseconds = time.millisecond.toString().padLeft(3, '0');
    return '${twoDigits(time.hour)}:${twoDigits(time.minute)}:'
        '${twoDigits(time.second)}.$milliseconds';
  }

  String _stringifyMessage(dynamic message) {
    final value = message is Function ? message() : message;
    if (value is Map || value is Iterable) {
      try {
        return jsonEncode(
          value,
          toEncodable: (object) => object.toString(),
        );
      } catch (_) {
        return value.toString();
      }
    }
    return value.toString();
  }

  Iterable<String> _formatStackTrace(StackTrace stackTrace) {
    return stackTrace
        .toString()
        .split('\n')
        .where((line) =>
            line.trim().isNotEmpty &&
            !line.contains('package:logger/') &&
            !line.contains('package:miru/services/logging/logger.dart'))
        .take(_stackFrameLimit)
        .map((line) => '  ${line.trim()}');
  }
}

class MiruLogOutput extends LogOutput {
  static final Lock _logLock = Lock();
  static String? _logFilePath;

  /// 单文件大小上限：超限轮转（F9）。
  static const int _maxLogBytes = 2 * 1024 * 1024; // 2MB

  /// 最多保留的轮转历史份数：log → .1 → .2（加上当前文件共 3 份）。
  static const List<String> _rotatedSuffixes = ['.1', '.2'];

  static Future<String> _getLogFilePath() async {
    if (_logFilePath != null) return _logFilePath!;

    final dir = (await getApplicationSupportDirectory()).path;
    final logDir = p.join(dir, "logs");
    final directory = Directory(logDir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _logFilePath = p.join(logDir, "miru_logs.log");
    return _logFilePath!;
  }

  @override
  void output(OutputEvent event) {
    for (var line in event.lines) {
      // 日志框架的最终出口，不能改调自身，否则无限递归。
      // ignore: avoid_print
      print(line);
    }

    // Write to file if: warning/error/fatal OR forceLog is enabled
    final forceLog = Zone.current[_forceLogKey] as bool? ?? false;
    if (event.level.index >= Level.warning.index || forceLog) {
      _writeToFile(event);
    }
  }

  void _writeToFile(OutputEvent event) {
    _logLock.synchronized(() async {
      try {
        final filePath = await _getLogFilePath();
        final file = File(filePath);

        // 写入前检查轮转：当前文件超限时 log→.1、.1→.2、删 .2，
        // 新内容落到新文件里（F9：warning 高频落盘曾致无限增长）。
        await _rotateIfNeeded(file);

        final buffer = StringBuffer();
        for (var line in event.lines) {
          final cleanLine = _removeAnsiCodes(line);
          buffer.writeln(cleanLine);
        }

        await file.writeAsString(
          buffer.toString(),
          mode: FileMode.writeOnlyAppend,
        );
      } catch (e) {
        // 写日志失败时只能走控制台兜底，不能递归调用日志框架。
        // ignore: avoid_print
        print('Failed to write log to file: ${_singleLineLogText(e)}');
      }
    });
  }

  /// 超过 [_maxLogBytes] 时轮转：.2 删除、.1→.2、当前→.1。
  /// 单次事件超大的极端情况（如带长堆栈的 fatal）允许暂时超限，
  /// 下一次写入时再轮转。轮转失败不阻塞写入（下次再试）。
  Future<void> _rotateIfNeeded(File file) async {
    try {
      if (!await file.exists()) return;
      if (await file.length() < _maxLogBytes) return;

      final rotated = [
        for (final suffix in _rotatedSuffixes) File('${file.path}$suffix'),
      ];
      // 后面的往前挪：先删最老（.2）——dart:io 的 rename 在 Windows 上
      // 不覆盖已存在的目标，不先删会让整条轮转链卡死；.1→.2，当前→.1。
      if (await rotated.last.exists()) {
        await rotated.last.delete();
      }
      for (var i = rotated.length - 1; i > 0; i--) {
        if (await rotated[i - 1].exists()) {
          await rotated[i - 1].rename(rotated[i].path);
        }
      }
      await file.rename(rotated.first.path);
    } catch (_) {
      // 轮转失败（平台文件占用等）：继续追加写当前文件。
    }
  }

  /// Remove ANSI escape codes from string to ensure clean log files
  String _removeAnsiCodes(String text) {
    return text.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
  }
}

class MiruLogger {
  MiruLogger._internal() {
    // 钉死级别（F22）：此前依赖 logger 包 Logger.level 的默认值，
    // release 下每请求的 d 级 HTTP 日志也可能打进 logcat；现在
    // release 只到 info，debug 全量（trace 起）。forceLog 区域不受
    // 影响（MiruLogFilter 先查 Zone 标记）。
    // 注意 MiruLogFilter 按 enum index 比较，故「全量」用 trace
    // （最低档）而不是语义化的 all。
    Logger.level = kReleaseMode ? Level.info : Level.trace;
    _logger = Logger(
      filter: MiruLogFilter(),
      printer: MiruLogPrinter(),
      output: MiruLogOutput(),
    );
  }

  static final MiruLogger _instance = MiruLogger._internal();
  factory MiruLogger() {
    return _instance;
  }

  late final Logger _logger;
  void _log(void Function() logFn, bool forceLog) {
    if (forceLog) {
      runZoned(logFn, zoneValues: {_forceLogKey: true});
    } else {
      logFn();
    }
  }

  /// Trace log - lowest level, very detailed information
  void t(dynamic message,
      {Object? error, StackTrace? stackTrace, bool forceLog = false}) {
    _log(
        () => _logger.t(message, error: error, stackTrace: stackTrace),
        forceLog);
  }

  /// Debug log - detailed information for debugging
  void d(dynamic message,
      {Object? error, StackTrace? stackTrace, bool forceLog = false}) {
    _log(
        () => _logger.d(message, error: error, stackTrace: stackTrace),
        forceLog);
  }

  /// Info log - informational messages
  void i(dynamic message,
      {Object? error, StackTrace? stackTrace, bool forceLog = false}) {
    _log(
        () => _logger.i(message, error: error, stackTrace: stackTrace),
        forceLog);
  }

  /// Warning log - potentially harmful situations
  void w(dynamic message,
      {Object? error, StackTrace? stackTrace, bool forceLog = false}) {
    _log(
        () => _logger.w(message, error: error, stackTrace: stackTrace),
        forceLog);
  }

  /// Error log - error events that might still allow the app to continue
  void e(dynamic message,
      {Object? error, StackTrace? stackTrace, bool forceLog = false}) {
    _log(
        () => _logger.e(message, error: error, stackTrace: stackTrace),
        forceLog);
  }

  /// Fatal log - very severe error events that may cause the app to abort.
  void f(dynamic message,
      {Object? error, StackTrace? stackTrace, bool forceLog = false}) {
    _log(
      () => _logger.f(
        message,
        error: error,
        stackTrace: stackTrace ?? StackTrace.current,
      ),
      forceLog,
    );
  }
}

Future<File> getLogsPath() async {
  final dir = (await getApplicationSupportDirectory()).path;
  final logDir = p.join(dir, "logs");
  final filename = p.join(logDir, "miru_logs.log");

  final directory = Directory(logDir);
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }

  final file = File(filename);
  if (!await file.exists()) {
    await MiruLogOutput._logLock.synchronized(() async {
      if (!await file.exists()) {
        await file.create();
      }
    });
  }
  return file;
}

Future<bool> clearLogs() async {
  try {
    final file = await getLogsPath();
    await MiruLogOutput._logLock.synchronized(() async {
      await file.writeAsString('');
      // 一并清掉轮转历史（F9）：「清空日志」应释放全部日志空间。
      for (final suffix in MiruLogOutput._rotatedSuffixes) {
        final rotated = File('${file.path}$suffix');
        if (await rotated.exists()) {
          await rotated.delete();
        }
      }
    });
    return true;
  } catch (e) {
    // 清理日志失败只能控制台告警。
    // ignore: avoid_print
    print('Error clearing file: ${_singleLineLogText(e)}');
    return false;
  }
}
