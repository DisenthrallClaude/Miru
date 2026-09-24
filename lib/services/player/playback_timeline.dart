import 'dart:math';

import 'package:miru/services/logging/logger.dart';

/// v1.7.0（§5）：播放关键路径时间线——「用户点了一集到画面出来」
/// 全程分段计时，用于量化秒开改造效果与线上归因。
///
/// 记录点（全部本地内存，不上报、不落盘）：
/// - [tTap]：用户触发换集（changeEpisode 进入）；
/// - [tResolveStart]：进入解析服务（resolveWithHeaders）；
/// - [tWinner]：竞速胜出（附胜出层级与 host）；
/// - [tOpen]：player.open 返回；
/// - [tFirstFrame]：mpv 首帧信号（video-params 宽高就绪）；
/// - [tFirstBufferEnd]：首次 buffering=false（画面稳定开始流动）；
/// - [failureReason]：任一环节失败的原因（时间线终止）。
///
/// 线程模型：所有方法都从 UI isolate 调用（播放链路本身在 UI isolate
/// 上跑），无需加锁；[PlaybackTimelineRecorder.instance] 是进程级单例，
/// 播放页销毁不清理——诊断数据要跨会话留存。
class PlaybackTimeline {
  PlaybackTimeline({
    required this.label,
    required this.episodeUrl,
    required this.tTap,
  });

  /// 展示名（番剧/集数，如「葬送的芙莉莲 第 3 集」）。
  final String label;

  /// 本集播放页 URL（缓存 key，用来对齐各记录点）。
  final String episodeUrl;

  /// 用户触发时刻（changeEpisode 进入 / 选源面板点下）。
  final DateTime tTap;

  /// 进入解析服务时刻。
  DateTime? tResolveStart;

  /// 竞速胜出时刻。
  DateTime? tWinner;

  /// 胜出层级：cache / fast / cloud / webview。
  String? winnerLevel;

  /// 胜出直链的 host（诊断用：定位慢站/坏站）。
  String? winnerHost;

  /// player.open 返回时刻。
  DateTime? tOpen;

  /// 首帧信号（video-params）时刻。
  DateTime? tFirstFrame;

  /// 首次 buffering=false 时刻。
  DateTime? tFirstBufferEnd;

  /// 失败原因（时间线终止）。
  String? failureReason;

  bool get succeeded => tFirstFrame != null || tFirstBufferEnd != null;

  Duration? get tapToFirstFrame => tFirstFrame?.difference(tTap);

  Duration? get tapToWinner => tWinner?.difference(tTap);

  Duration? get winnerToFirstFrame =>
      (tWinner == null || tFirstFrame == null)
          ? null
          : tFirstFrame!.difference(tWinner!);

  Duration? get resolveToWinner =>
      (tResolveStart == null || tWinner == null)
          ? null
          : tWinner!.difference(tResolveStart!);

  String _fmtMs(Duration? d) => d == null ? '-' : '${d.inMilliseconds}ms';

  /// 单条时间线导出（诊断页/剪贴板用）。
  String export() {
    final buffer = StringBuffer();
    buffer.writeln('[$label] ${succeeded ? "OK" : "FAIL"}'
        '${failureReason == null ? "" : " ($failureReason)"}');
    buffer.writeln('  tap→resolve: ${_fmtMs(tResolveStart?.difference(tTap))}'
        '  resolve→winner: ${_fmtMs(resolveToWinner)}'
        '  winner: ${winnerLevel ?? '-'}@${winnerHost ?? '-'}');
    buffer.writeln('  tap→open: ${_fmtMs(tOpen?.difference(tTap))}'
        '  winner→frame: ${_fmtMs(winnerToFirstFrame)}'
        '  frame→bufferEnd: ${_fmtMs((tFirstFrame == null || tFirstBufferEnd == null) ? null : tFirstBufferEnd!.difference(tFirstFrame!))}');
    buffer.writeln('  总耗时(点按→首帧): ${_fmtMs(tapToFirstFrame)}');
    return buffer.toString();
  }
}

/// 时间线记录器（进程级单例）。
///
/// 「当前时间线」语义：一次换集 begin 一次，后续记录点只写入与
/// [PlaybackTimeline.episodeUrl] 匹配的当前条目——换集竞态下旧流程的
/// 迟到记录不会污染新集的时间线（key 不匹配直接丢弃）。
class PlaybackTimelineRecorder {
  PlaybackTimelineRecorder._();

  static final PlaybackTimelineRecorder instance = PlaybackTimelineRecorder._();

  /// 保留条数上限（环形缓冲；§5 要求最近 50 条）。
  static const int capacity = 50;

  final List<PlaybackTimeline> _records = [];

  PlaybackTimeline? _current;

  /// 只读视图（最新在前）。
  List<PlaybackTimeline> get records =>
      List.unmodifiable(_records.reversed.toList());

  PlaybackTimeline? get current => _current;

  /// 开始一条新时间线（换集/changeEpisode 进入时）。
  PlaybackTimeline begin({
    required String label,
    required String episodeUrl,
  }) {
    final timeline = PlaybackTimeline(
      label: label,
      episodeUrl: episodeUrl,
      tTap: DateTime.now(),
    );
    _records.add(timeline);
    if (_records.length > capacity) {
      _records.removeRange(0, _records.length - capacity);
    }
    _current = timeline;
    return timeline;
  }

  void _apply(String episodeUrl, void Function(PlaybackTimeline t) fn) {
    final current = _current;
    if (current == null || current.episodeUrl != episodeUrl) return;
    fn(current);
  }

  /// 选源面板点下（P1-5 投机解析）：把 tTap 提前到真实点击时刻。
  /// 只在尚无当前时间线、或当前时间线已结束时前移——普通换集随后的
  /// begin() 会覆盖，不会重复计时。
  void markTap({required String label, required String episodeUrl}) {
    final current = _current;
    if (current != null &&
        current.episodeUrl == episodeUrl &&
        !current.succeeded &&
        current.failureReason == null &&
        current.tWinner == null) {
      // 同一集重复点击：只更新 label，不重置计时起点。
      return;
    }
    begin(label: label, episodeUrl: episodeUrl);
  }

  void recordResolveStart(String episodeUrl) =>
      _apply(episodeUrl, (t) => t.tResolveStart ??= DateTime.now());

  void recordWinner(
    String episodeUrl, {
    required String level,
    String? host,
  }) =>
      _apply(episodeUrl, (t) {
        t.tWinner ??= DateTime.now();
        t.winnerLevel ??= level;
        t.winnerHost ??= host;
      });

  void recordOpen() {
    // v1.7.0（§5）：无键记录——调用点（video_controller init 成功分支）
    // 已过 session.isActive 陈旧检查，不存在旧流污染新时间线的窗口。
    final current = _current;
    if (current == null) return;
    current.tOpen ??= DateTime.now();
  }

  /// 首帧（由 playback 层 onFirstFrame 钩子转发）。
  /// 每集只记一次（??=），换集 begin 新时间线后自动重新计。
  void recordFirstFrame() {
    final current = _current;
    if (current == null) return;
    current.tFirstFrame ??= DateTime.now();
  }

  /// 首次缓冲结束：仅当首帧已出（帧后 bufferEnd 才有意义；避免换集
  /// 过渡期的 buffering 事件提前盖章）。
  void recordFirstBufferEnd() {
    final current = _current;
    if (current == null || current.tFirstFrame == null) return;
    current.tFirstBufferEnd ??= DateTime.now();
  }

  void fail(String reason) {
    // 无键记录：_failLoading 只在当前流内触发，换集竞态下旧流的
    // 迟到失败由 MobX session 守卫拦在调用点之前。
    final current = _current;
    if (current == null) return;
    current.failureReason ??= reason;
  }

  // ---------------------------------------------------------------------
  // 统计（P50/P90）
  // ---------------------------------------------------------------------

  /// 点按→首帧的 P50/P90（仅统计成功样本）。
  /// 返回 null 表示样本不足（诊断页显示「暂无数据」）。
  ({Duration? p50, Duration? p90, int samples}) tapToFirstFrameStats() {
    return _stats((t) => t.tapToFirstFrame);
  }

  /// 解析→胜出的 P50/P90（纯解析段，不含播放器装配）。
  ({Duration? p50, Duration? p90, int samples}) resolveStats() {
    return _stats((t) => t.resolveToWinner);
  }

  ({Duration? p50, Duration? p90, int samples}) _stats(
      Duration? Function(PlaybackTimeline t) selector) {
    final values = _records
        .map(selector)
        .whereType<Duration>()
        .map((d) => d.inMilliseconds)
        .toList()
      ..sort();
    if (values.isEmpty) {
      return (p50: null, p90: null, samples: 0);
    }
    Duration percentile(double p) {
      final idx = min(values.length - 1, (p * (values.length - 1)).round());
      return Duration(milliseconds: values[idx]);
    }

    return (p50: percentile(0.5), p90: percentile(0.9), samples: values.length);
  }

  /// 全量导出为文本（剪贴板用）：统计头 + 每条时间线。
  String exportAll() {
    final buffer = StringBuffer();
    final tap = tapToFirstFrameStats();
    final resolve = resolveStats();
    buffer.writeln('== Miru 播放诊断（最近 ${_records.length} 条）==');
    buffer.writeln('点按→首帧 P50: ${tap.p50?.inMilliseconds ?? '-'}ms'
        '  P90: ${tap.p90?.inMilliseconds ?? '-'}ms'
        '  样本: ${tap.samples}');
    buffer.writeln('解析段   P50: ${resolve.p50?.inMilliseconds ?? '-'}ms'
        '  P90: ${resolve.p90?.inMilliseconds ?? '-'}ms'
        '  样本: ${resolve.samples}');
    buffer.writeln();
    for (final t in _records.reversed) {
      buffer.writeln(t.export());
    }
    return buffer.toString();
  }

  /// 清空（诊断页「清除」按钮 / 清缓存联动）。
  void clear() {
    _records.clear();
    _current = null;
    MiruLogger().d('PlaybackTimeline: cleared');
  }
}
