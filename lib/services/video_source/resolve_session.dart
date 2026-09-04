import 'dart:async';

import 'package:miru/services/logging/logger.dart';

/// 解析链路竞速的阶段标识（阶段 2 / §2）。
enum ResolveStage {
  /// 本地快速静态解析（t=0 启动）。
  fast,

  /// 云端解析层（t=600ms 仍无 verified 结果时启动）。
  cloud,

  /// WebView 嗅探兜底（t=1500ms 仍无 verified 结果时启动）。
  webview,
}

/// 解析链路环形日志（阶段 2 / §2.5）。
///
/// 保留最近 [capacity] 条带时间戳的阶段事件，用于「为什么这一集
/// 播了 8 秒」的事后归因；不落盘（体积考虑），可整段导出到
/// 日志面板或错误报告。
class ResolveTrace {
  ResolveTrace({this.capacity = 500});

  final int capacity;
  final List<(DateTime, ResolveStage, String, String?)> _entries = [];

  void record(ResolveStage stage, String event, [String? detail]) {
    if (_entries.length >= capacity) {
      _entries.removeAt(0);
    }
    _entries.add((DateTime.now(), stage, event, detail));
  }

  /// 导出为多行文本（时间相对会话起点，毫秒）。
  String export() {
    if (_entries.isEmpty) return '<empty trace>';
    final t0 = _entries.first.$1;
    final buffer = StringBuffer();
    for (final (at, stage, event, detail) in _entries) {
      final ms = at.difference(t0).inMilliseconds;
      buffer.writeln('$ms\t${stage.name}\t$event'
          '${detail == null ? '' : '\t$detail'}');
    }
    return buffer.toString();
  }

  bool get isEmpty => _entries.isEmpty;
}

/// 从 URL 推导解析结果的缓存 TTL（阶段 2 / §2.4）。
///
/// 带签名的 CDN 直链通常在 URL 查询里携带过期时间戳（exp / expire /
/// expires / e / x-oss-expires …秒或毫秒）。从中提取并 clamp 到
/// [min]~[max]：取不到返回 null（调用方用默认 TTL）。
Duration? ttlFor(
  String url, {
  Duration min = const Duration(minutes: 1),
  Duration max = const Duration(hours: 6),
}) {
  final Uri parsed;
  try {
    parsed = Uri.parse(url);
  } catch (_) {
    return null;
  }
  const keys = ['exp', 'expire', 'expires', 'e', 'x-oss-expires', 't'];
  for (final key in keys) {
    final values = parsed.queryParametersAll[key];
    if (values == null || values.isEmpty) continue;
    final raw = values.last;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) continue;
    // 秒级时间戳 < 10^12（2100 年前的毫秒值不会低于此），
    // 毫秒级则除以 1000。
    final seconds = value > 1000000000000 ? value ~/ 1000 : value;
    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative) return min; // 已过期：仍给 1min，由探测纠偏
    if (remaining < min) return min;
    if (remaining > max) return max;
    return remaining;
  }
  return null;
}

/// 一个参与竞速的层级任务（§2 波次调度）。
///
/// 返回 null 表示「本层放弃」（提取失败/候选全灭/未配置），竞速继续
/// 等下一波；抛异常表示「本层故障」，同样只记日志不终止竞速——
/// 竞速只认「首个非空产出」或硬上限。
typedef ResolveLevelTask<T> = Future<T?> Function(ResolveTrace trace);

/// 对冲竞速会话（阶段 2 / §2.2）：多波次启动层级任务，首个产出者
/// 胜出并取消其余在途任务；硬上限兜底。
///
/// 波次语义（§2.1）：
/// - t=0 启动 fast；
/// - t=[cloudDelay]（600ms）仍无 verified → 启动 cloud；
/// - t=[webviewDelay]（1500ms）仍无 verified → 启动 webview；
/// - t=[hardDeadline]（12s）仍无 → 抛 [TimeoutException]，交上层
///   兜底换源（绝不无界等待）。
///
/// 「产出」的语义由调用方定义：层级任务返回的对象即视为已验证
/// （hybrid 层把探测放在各层级任务内部，首个通过探测的候选即产出）。
class ResolveSession<T> {
  ResolveSession({
    required this.waves,
    required this.hardDeadline,
    this.onTrace,
  }) : assert(waves.isNotEmpty, 'waves must not be empty');

  /// 波次表：启动延迟 → 任务。延迟需升序排列（不满足将排序修正）。
  final Map<Duration, ResolveLevelTask<T>> waves;

  /// 竞速硬上限：到点无产出即失败。
  final Duration hardDeadline;

  /// 每个层级启动/完成/产出/取消时回调（日志面板用）。
  final void Function(ResolveTrace trace)? onTrace;

  /// 阶段名（日志用），取波次任务无法直接携带，由调用方在 onTrace
  /// 中自行区分。
  final ResolveTrace trace = ResolveTrace();

  Completer<T>? _completer;
  Timer? _deadlineTimer;
  final List<Timer> _waveTimers = [];
  final List<Future<void>> _inflight = [];
  bool _cancelled = false;

  /// 是否已有层级产出（防止后续波次在胜者产生后仍然启动）。
  bool _won = false;

  /// 竞速主体。同一会话只能跑一次。
  Future<T> run() {
    if (_completer != null) {
      throw StateError('ResolveSession.run() called twice');
    }
    final completer = Completer<T>();
    _completer = completer;

    trace.record(waves.entries.first.key == Duration.zero
        ? ResolveStage.fast
        : ResolveStage.cloud, 'session-start',
        '${waves.length} waves, deadline ${hardDeadline.inMilliseconds}ms');
    onTrace?.call(trace);

    final ordered = waves.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final entry in ordered) {
      if (entry.key == Duration.zero) {
        _launch(entry.key, entry.value);
      } else {
        _waveTimers.add(Timer(entry.key, () {
          if (_won || _cancelled || completer.isCompleted) return;
          _launch(entry.key, entry.value);
        }));
      }
    }

    _deadlineTimer = Timer(hardDeadline, () {
      if (!completer.isCompleted) {
        trace.record(ResolveStage.fast, 'hard-deadline',
            'no winner after ${hardDeadline.inMilliseconds}ms');
        onTrace?.call(trace);
        _cancelInflight();
        completer.completeError(
          TimeoutException('resolve race exceeded hard deadline', hardDeadline),
        );
      }
    });

    return completer.future;
  }

  void _launch(Duration delay, ResolveLevelTask<T> task) {
    trace.record(_stageFor(delay), 'wave-launch',
        'after ${delay.inMilliseconds}ms');
    onTrace?.call(trace);
    final future = task(trace).then((result) {
      if (_won || _cancelled || _completer!.isCompleted) return;
      if (result != null) {
        _win(result);
      } else {
        trace.record(_stageFor(delay), 'wave-yield', 'no result');
        onTrace?.call(trace);
      }
    }).catchError((Object e) {
      if (_won || _cancelled || _completer!.isCompleted) return;
      trace.record(_stageFor(delay), 'wave-error', '$e');
      onTrace?.call(trace);
      // 层级故障不终止竞速：还有后续波次与硬上限兜底。
    });
    _inflight.add(future);
  }

  ResolveStage _stageFor(Duration delay) {
    // 波次延迟 → 阶段名的粗映射（仅日志用途）。
    if (delay == Duration.zero) return ResolveStage.fast;
    if (delay <= const Duration(milliseconds: 800)) return ResolveStage.cloud;
    return ResolveStage.webview;
  }

  void _win(T result) {
    _won = true;
    _cancelTimers();
    _cancelInflight();
    trace.record(ResolveStage.fast, 'winner', '$runtimeType produced');
    onTrace?.call(trace);
    if (!_completer!.isCompleted) {
      _completer!.complete(result);
    }
  }

  /// 外部取消（用户换集/退出播放页）：所有在途任务收到取消信号，
  /// 会话以 [TimeoutException] 失败（调用方按「用户已离开」忽略）。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelTimers();
    _cancelInflight();
    trace.record(ResolveStage.fast, 'cancelled-by-user');
    onTrace?.call(trace);
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        TimeoutException('resolve session cancelled', null),
      );
    }
  }

  void _cancelTimers() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    for (final timer in _waveTimers) {
      timer.cancel();
    }
    _waveTimers.clear();
  }

  /// 取消在途层级任务：这里只能「不再等待」（层级任务是普通 Future），
  /// 真正的资源回收靠各层级内部的取消钩子（hybrid 层的 cancel 语义）。
  void _cancelInflight() {
    // 置位 _won / _cancelled 后，各 future 的 then 回调直接短路，
    // 不再触发产出。这是 Dart 无结构化取消下的标准做法。
    MiruLogger().d('ResolveSession: cancelled ${_inflight.length} inflight');
  }
}
