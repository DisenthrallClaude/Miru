import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// v1.8.1：更新包「多镜像测速择优 + 分块并发 + 断点续传 + 失败换源」下载器。
///
/// 背景：国内直连 GitHub Releases 基本不可达；v1.8.0 只有一个镜像前缀、
/// 用「Range 0-0 谁先应答」选源（应答快≠带宽大），且单连接串行下载，
/// 公共反代普遍按连接限速，81MB 的 APK 常常要下十几分钟甚至断流。
///
/// 本实现：
/// 1. **测速**：所有候选（若干 GitHub 加速镜像 + 直连）并发各拉前 512KB，
///    最多 4 秒，按真实吞吐排序；校验 206/Content-Range 总长与 APK 魔数
///    （`PK\x03\x04`），把返回 HTML 错误页 / 限流页的镜像直接剔除。
/// 2. **分块并发**：文件切成 4MB 块放入队列，4 个 worker 抢块下载
///    （work stealing，慢连接不会拖住整体）；吞吐不低于最快源一半的
///    镜像都参与，worker 轮流分配到不同镜像，叠加多个反代的带宽。
/// 3. **断点续传**：数据写入预分配的 `.part`，每块进度落盘到
///    `.part.json`；进程被杀或用户取消后，下次从各块断点继续。
/// 4. **失败换源**：块失败回队列；同一镜像连续失败 2 次即拉黑，worker
///    改用下一个健康源；全部拉黑时重新测速一轮。
/// 5. **校验**：整包 sha256 与 Release digest 比对，不一致删档重来一次。
///    不支持 Range 的源退化为单连接整包下载。
///
/// 纯 Dart、传输层可注入（[RangeTransport]），便于单测覆盖。
class MirrorDownloader {
  MirrorDownloader({
    required this.transport,
    this.workers = 4,
    this.chunkSize = 4 * 1024 * 1024,
    this.probeBytes = 512 * 1024,
    this.probeTimeout = const Duration(seconds: 4),
    this.idleTimeout = const Duration(seconds: 15),
    this.maxFailuresPerSource = 2,
    this.maxRounds = 3,
  });

  final RangeTransport transport;
  final int workers;
  final int chunkSize;
  final int probeBytes;
  final Duration probeTimeout;
  final Duration idleTimeout;
  final int maxFailuresPerSource;
  final int maxRounds;

  bool _cancelled = false;
  final List<RangeCancel> _inflight = [];

  void cancel() {
    _cancelled = true;
    for (final c in List.of(_inflight)) {
      c.cancel();
    }
  }

  bool get isCancelled => _cancelled;

  /// 为一个原始下载地址构造候选：镜像前缀在前、直连在最后。
  static List<String> buildCandidates(String url, List<String> prefixes) {
    final out = <String>[];
    for (final p in prefixes) {
      if (p.isEmpty || url.startsWith(p)) continue;
      final c = '$p$url';
      if (!out.contains(c)) out.add(c);
    }
    if (!out.contains(url)) out.add(url);
    return out;
  }

  /// 候选地址的展示名（主机名），用于进度行「来源」。
  static String sourceLabel(String candidate) {
    try {
      final host = Uri.parse(candidate).host;
      if (host == 'github.com' || host.endsWith('githubusercontent.com')) {
        return 'GitHub 直连';
      }
      return host;
    } catch (_) {
      return candidate;
    }
  }

  /// 并发测速。返回按吞吐降序的结果（失败项 bytesPerSecond = -1，排最后）。
  Future<List<ProbeResult>> probe(List<String> candidates,
      {int? expectedSize}) async {
    final results = await Future.wait(candidates.map((c) async {
      final sw = Stopwatch()..start();
      final cancel = RangeCancel();
      _inflight.add(cancel);
      var bytes = 0;
      int? total;
      String? error;
      var rangeOk = false;
      final head = <int>[];
      try {
        final resp = await transport
            .get(c, start: 0, end: probeBytes - 1, cancel: cancel)
            .timeout(probeTimeout);
        if (resp.statusCode != 206 && resp.statusCode != 200) {
          throw HttpException('HTTP ${resp.statusCode}');
        }
        rangeOk = resp.statusCode == 206;
        total = resp.totalSize ?? (rangeOk ? null : resp.contentLength);
        // 总时长上限：到点就停止读取，用已到达的字节数计算吞吐，照样参与排名。
        final remaining = probeTimeout - sw.elapsed;
        final done = Completer<void>();
        late final StreamSubscription<List<int>> sub;
        sub = resp.body.listen((chunk) {
          if (head.length < 4) {
            head.addAll(chunk.take(4 - head.length));
          }
          bytes += chunk.length;
          if (bytes >= probeBytes && !done.isCompleted) done.complete();
        }, onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        }, onDone: () {
          if (!done.isCompleted) done.complete();
        }, cancelOnError: true);
        final timer = Timer(
            remaining.isNegative ? Duration.zero : remaining, () {
          if (!done.isCompleted) done.complete();
        });
        try {
          await done.future;
        } finally {
          timer.cancel();
          unawaited(sub.cancel());
        }
        cancel.cancel();
        if (head.length >= 4 && !_isZipMagic(head)) {
          throw const FormatException('不是 APK（可能是错误页/限流页）');
        }
        if (bytes == 0) throw const FormatException('无数据');
        if (expectedSize != null &&
            expectedSize > 0 &&
            total != null &&
            total != expectedSize) {
          throw FormatException('大小不符 $total != $expectedSize');
        }
      } catch (e) {
        error = e.toString();
        bytes = 0;
      } finally {
        cancel.cancel();
        _inflight.remove(cancel);
      }
      final ms = math.max(1, sw.elapsedMilliseconds);
      return ProbeResult(
        candidate: c,
        bytesPerSecond: error == null ? bytes * 1000 / ms : -1,
        latencyMs: ms,
        supportsRange: error == null && rangeOk,
        totalSize: error == null ? total : null,
        error: error,
      );
    }));
    results.sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
    return results;
  }

  static bool _isZipMagic(List<int> head) =>
      head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04;

  /// 下载 [url] 到 [destPath]。
  ///
  /// [expectedSha256] 为空时跳过校验（Release 资产缺 digest 的历史包）。
  /// [onProgress] 约每 300ms 回调一次。
  Future<DownloadOutcome> download({
    required String url,
    required List<String> mirrorPrefixes,
    required String destPath,
    String expectedSha256 = '',
    int? expectedSize,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    _cancelled = false;
    final candidates = buildCandidates(url, mirrorPrefixes);
    final partPath = '$destPath.part';
    final statePath = '$destPath.part.json';

    Object? lastError;
    List<ProbeResult> lastProbe = const [];
    for (var round = 1; round <= maxRounds; round++) {
      _checkCancelled();
      onProgress?.call(DownloadProgress.probing(round: round));
      lastProbe = await probe(candidates, expectedSize: expectedSize);
      _checkCancelled();
      final healthy = lastProbe.where((p) => p.ok).toList();
      if (healthy.isEmpty) {
        lastError = Exception(
            '所有下载源均不可用：${lastProbe.map((p) => '${sourceLabel(p.candidate)}(${p.error})').join('，')}');
        continue;
      }
      final size = expectedSize ??
          healthy.firstWhere((p) => p.totalSize != null,
                  orElse: () => healthy.first)
              .totalSize;
      try {
        final ranged = healthy.where((p) => p.supportsRange).toList();
        if (size != null && size > 0 && ranged.isNotEmpty) {
          await _segmented(
            sources: ranged,
            size: size,
            partPath: partPath,
            statePath: statePath,
            onProgress: onProgress,
          );
        } else {
          await _single(
            source: healthy.first,
            partPath: partPath,
            statePath: statePath,
            onProgress: onProgress,
          );
        }
        _checkCancelled();
        onProgress?.call(DownloadProgress.verifying(size ?? 0));
        if (expectedSha256.isNotEmpty) {
          final actual = await sha256OfFile(File(partPath));
          if (actual != expectedSha256) {
            await _deleteQuietly(partPath);
            await _deleteQuietly(statePath);
            throw IntegrityException(expectedSha256, actual);
          }
        }
        final dest = File(destPath);
        if (await dest.exists()) await dest.delete();
        await File(partPath).rename(destPath);
        await _deleteQuietly(statePath);
        return DownloadOutcome(path: destPath, probe: lastProbe);
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        if (_cancelled) throw const DownloadCancelled();
        lastError = e;
      }
    }
    throw lastError ?? Exception('所有下载源均不可用');
  }

  void _checkCancelled() {
    if (_cancelled) throw const DownloadCancelled();
  }

  Future<void> _segmented({
    required List<ProbeResult> sources,
    required int size,
    required String partPath,
    required String statePath,
    void Function(DownloadProgress)? onProgress,
  }) async {
    final state = await _loadOrInitState(statePath, partPath, size);
    final best = sources.first.bytesPerSecond;
    // 吞吐不低于最快源一半的都参与（至多 3 个），多镜像叠加带宽。
    final pool = sources
        .where((s) => s.bytesPerSecond >= best * 0.5)
        .take(3)
        .map((s) => s.candidate)
        .toList();
    final backups =
        sources.map((s) => s.candidate).where((c) => !pool.contains(c));
    final order = [...pool, ...backups];
    final failures = <String, int>{};
    bool alive(String c) => (failures[c] ?? 0) < maxFailuresPerSource;

    final raf = await File(partPath).open(mode: FileMode.append);
    final queue = <_Chunk>[
      for (final c in state.chunks)
        if (!c.done) c,
    ];
    var received = state.chunks.fold<int>(0, (a, c) => a + c.received);
    final baseline = received;
    final perSource = <String, int>{};
    final meter = _SpeedMeter();
    final sw = Stopwatch()..start();
    var lastEmit = Duration.zero;
    var lastPersist = Duration.zero;
    var writeLock = Future<void>.value();

    void emit({bool force = false}) {
      final now = sw.elapsed;
      if (!force && now - lastEmit < const Duration(milliseconds: 300)) return;
      lastEmit = now;
      meter.sample(received, now);
      final active = perSource.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      onProgress?.call(DownloadProgress(
        phase: DownloadPhase.downloading,
        received: received,
        total: size,
        bytesPerSecond: meter.speed,
        sources: active.map((e) => sourceLabel(e.key)).toList(),
        resumedBytes: baseline,
      ));
    }

    Future<void> persist({bool force = false}) async {
      final now = sw.elapsed;
      if (!force && now - lastPersist < const Duration(seconds: 1)) return;
      lastPersist = now;
      await _saveState(statePath, state);
    }

    Future<void> worker(int index) async {
      while (true) {
        if (_cancelled) return;
        if (queue.isEmpty) return;
        final chunk = queue.removeAt(0);
        final usable = order.where(alive).toList();
        if (usable.isEmpty) {
          queue.insert(0, chunk);
          throw Exception('所有下载源都失败了');
        }
        // worker 轮流分配到参与池里的不同镜像；池子全挂则顺延到备选。
        final poolAlive = pool.where(alive).toList();
        final src = poolAlive.isNotEmpty
            ? poolAlive[index % poolAlive.length]
            : usable.first;
        final cancel = RangeCancel();
        _inflight.add(cancel);
        try {
          final from = chunk.start + chunk.received;
          final resp = await transport
              .get(src, start: from, end: chunk.end, cancel: cancel)
              .timeout(idleTimeout);
          if (resp.statusCode != 206) {
            throw HttpException('期望 206，实际 ${resp.statusCode}');
          }
          final cr = resp.rangeStart;
          if (cr != null && cr != from) {
            throw HttpException('Content-Range 起点错位 $cr != $from');
          }
          var pos = from;
          await for (final data in resp.body.timeout(idleTimeout)) {
            if (_cancelled) break;
            final remain = chunk.end + 1 - pos;
            final slice =
                data.length > remain ? data.sublist(0, remain) : data;
            if (slice.isEmpty) break;
            final at = pos;
            pos += slice.length;
            writeLock = writeLock.then((_) async {
              await raf.setPosition(at);
              await raf.writeFrom(slice);
            });
            await writeLock;
            chunk.received += slice.length;
            received += slice.length;
            perSource[src] = (perSource[src] ?? 0) + slice.length;
            emit();
            await persist();
            if (pos > chunk.end) break;
          }
          cancel.cancel();
          if (_cancelled) {
            queue.insert(0, chunk);
            return;
          }
          if (chunk.start + chunk.received <= chunk.end) {
            throw const HttpException('连接提前结束');
          }
          chunk.done = true;
          failures[src] = 0;
        } catch (e) {
          if (_cancelled) {
            queue.insert(0, chunk);
            return;
          }
          cancel.cancel();
          failures[src] = (failures[src] ?? 0) + 1;
          queue.insert(0, chunk);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        } finally {
          _inflight.remove(cancel);
        }
      }
    }

    try {
      final n = math.max(1, math.min(workers, queue.length));
      await Future.wait([for (var i = 0; i < n; i++) worker(i)]);
      await writeLock;
      await raf.flush();
    } finally {
      await raf.close();
      await _saveState(statePath, state);
    }
    emit(force: true);
    _checkCancelled();
    if (state.chunks.any((c) => !c.done)) {
      throw Exception('下载未完成');
    }
  }

  Future<void> _single({
    required ProbeResult source,
    required String partPath,
    required String statePath,
    void Function(DownloadProgress)? onProgress,
  }) async {
    await _deleteQuietly(statePath);
    final cancel = RangeCancel();
    _inflight.add(cancel);
    final meter = _SpeedMeter();
    final sw = Stopwatch()..start();
    var lastEmit = Duration.zero;
    final sink = File(partPath).openWrite(mode: FileMode.write);
    var received = 0;
    try {
      final resp = await transport
          .get(source.candidate, cancel: cancel)
          .timeout(idleTimeout);
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      await for (final data in resp.body.timeout(idleTimeout)) {
        if (_cancelled) break;
        sink.add(data);
        received += data.length;
        final now = sw.elapsed;
        if (now - lastEmit >= const Duration(milliseconds: 300)) {
          lastEmit = now;
          meter.sample(received, now);
          onProgress?.call(DownloadProgress(
            phase: DownloadPhase.downloading,
            received: received,
            total: total ?? 0,
            bytesPerSecond: meter.speed,
            sources: [sourceLabel(source.candidate)],
          ));
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
      _inflight.remove(cancel);
    }
    _checkCancelled();
  }

  Future<_State> _loadOrInitState(
      String statePath, String partPath, int size) async {
    final part = File(partPath);
    final stateFile = File(statePath);
    if (await stateFile.exists() && await part.exists()) {
      try {
        final raw = jsonDecode(await stateFile.readAsString());
        final s = _State.fromJson(raw as Map<String, dynamic>);
        if (s.size == size &&
            s.chunkSize == chunkSize &&
            await part.length() == size) {
          return s;
        }
      } catch (_) {}
    }
    // 新建：预分配文件，切块。
    await _deleteQuietly(partPath);
    final raf = await part.open(mode: FileMode.write);
    await raf.truncate(size);
    await raf.close();
    final chunks = <_Chunk>[];
    for (var start = 0; start < size; start += chunkSize) {
      chunks.add(_Chunk(start, math.min(size, start + chunkSize) - 1));
    }
    final s = _State(size, chunkSize, chunks);
    await _saveState(statePath, s);
    return s;
  }

  Future<void> _saveState(String statePath, _State s) async {
    try {
      final tmp = File('$statePath.tmp');
      await tmp.writeAsString(jsonEncode(s.toJson()), flush: true);
      await tmp.rename(statePath);
    } catch (_) {}
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 分块流式 sha256（不把几十 MB 读进内存）。
Future<String> sha256OfFile(File file) async {
  final out = _DigestSink();
  final sink = sha256.startChunkedConversion(out);
  await for (final c in file.openRead()) {
    sink.add(c);
  }
  sink.close();
  return out.value.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

// --------------------------------------------------------------- 传输层

class RangeCancel {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void onCancel(void Function() f) {
    if (_cancelled) {
      f();
    } else {
      _listeners.add(f);
    }
  }
}

class RangeResponse {
  RangeResponse({
    required this.statusCode,
    required this.body,
    this.contentLength,
    this.contentRange,
  });

  final int statusCode;
  final Stream<List<int>> body;
  final int? contentLength;
  final String? contentRange;

  static final _cr = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)');

  int? get rangeStart {
    final m = _cr.firstMatch(contentRange ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  }

  int? get totalSize {
    final m = _cr.firstMatch(contentRange ?? '');
    if (m == null || m.group(3) == '*') return null;
    return int.parse(m.group(3)!);
  }
}

abstract class RangeTransport {
  /// [start]/[end] 为 null 表示整包；[end] 含端点。
  Future<RangeResponse> get(String url,
      {int? start, int? end, RangeCancel? cancel});
}

/// dart:io HttpClient 实现（跟随重定向，镜像普遍 302 到 CDN）。
class IoRangeTransport implements RangeTransport {
  IoRangeTransport({HttpClient? client, this.userAgent = 'Miru-Updater'})
      : _client = client ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 8)
              ..idleTimeout = const Duration(seconds: 15));

  final HttpClient _client;
  final String userAgent;

  @override
  Future<RangeResponse> get(String url,
      {int? start, int? end, RangeCancel? cancel}) async {
    final req = await _client.getUrl(Uri.parse(url));
    req.followRedirects = true;
    req.maxRedirects = 8;
    req.headers.set(HttpHeaders.userAgentHeader, userAgent);
    if (start != null) {
      req.headers.set(HttpHeaders.rangeHeader,
          'bytes=$start-${end == null ? '' : end.toString()}');
    }
    cancel?.onCancel(() => req.abort());
    final resp = await req.close();
    final ctrl = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    ctrl.onListen = () {
      sub = resp.listen(ctrl.add,
          onError: ctrl.addError, onDone: ctrl.close, cancelOnError: true);
    };
    ctrl.onCancel = () async {
      await sub?.cancel();
    };
    cancel?.onCancel(() {
      sub?.cancel();
      if (!ctrl.isClosed) ctrl.close();
    });
    return RangeResponse(
      statusCode: resp.statusCode,
      body: ctrl.stream,
      contentLength: resp.contentLength >= 0 ? resp.contentLength : null,
      contentRange: resp.headers.value(HttpHeaders.contentRangeHeader),
    );
  }

  void close() => _client.close(force: true);
}

// --------------------------------------------------------------- 结果/进度

class ProbeResult {
  const ProbeResult({
    required this.candidate,
    required this.bytesPerSecond,
    required this.latencyMs,
    required this.supportsRange,
    this.totalSize,
    this.error,
  });

  final String candidate;
  final double bytesPerSecond;
  final int latencyMs;
  final bool supportsRange;
  final int? totalSize;
  final String? error;

  bool get ok => error == null && bytesPerSecond > 0;

  @override
  String toString() => ok
      ? '${MirrorDownloader.sourceLabel(candidate)} ${(bytesPerSecond / 1048576).toStringAsFixed(2)}MB/s'
      : '${MirrorDownloader.sourceLabel(candidate)} ✗ $error';
}

enum DownloadPhase { probing, downloading, verifying }

class DownloadProgress {
  const DownloadProgress({
    required this.phase,
    this.received = 0,
    this.total = 0,
    this.bytesPerSecond = 0,
    this.sources = const [],
    this.round = 1,
    this.resumedBytes = 0,
  });

  factory DownloadProgress.probing({int round = 1}) =>
      DownloadProgress(phase: DownloadPhase.probing, round: round);

  factory DownloadProgress.verifying(int total) => DownloadProgress(
      phase: DownloadPhase.verifying, received: total, total: total);

  final DownloadPhase phase;
  final int received;
  final int total;
  final double bytesPerSecond;
  final List<String> sources;
  final int round;
  final int resumedBytes;

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;

  Duration? get eta {
    if (total <= 0 || bytesPerSecond <= 1) return null;
    return Duration(
        seconds: ((total - received) / bytesPerSecond).ceil().clamp(0, 86400));
  }
}

class DownloadOutcome {
  const DownloadOutcome({required this.path, required this.probe});
  final String path;
  final List<ProbeResult> probe;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => '下载已取消';
}

class IntegrityException implements Exception {
  IntegrityException(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() => '文件完整性验证失败: 期望 $expected，实际 $actual';
}

// --------------------------------------------------------------- 内部

class _Chunk {
  _Chunk(this.start, this.end, {this.received = 0, this.done = false});
  final int start;
  final int end; // inclusive
  int received;
  bool done;

  Map<String, dynamic> toJson() =>
      {'s': start, 'e': end, 'r': received, 'd': done};

  factory _Chunk.fromJson(Map<String, dynamic> j) => _Chunk(
      j['s'] as int, j['e'] as int,
      received: j['r'] as int, done: j['d'] as bool);
}

class _State {
  _State(this.size, this.chunkSize, this.chunks);
  final int size;
  final int chunkSize;
  final List<_Chunk> chunks;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'size': size,
        'chunk': chunkSize,
        'chunks': chunks.map((c) => c.toJson()).toList(),
      };

  factory _State.fromJson(Map<String, dynamic> j) => _State(
        j['size'] as int,
        j['chunk'] as int,
        (j['chunks'] as List)
            .map((e) => _Chunk.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// 2 秒滑动窗口测速，避免瞬时值乱跳。
class _SpeedMeter {
  final List<(Duration, int)> _samples = [];
  double speed = 0;

  void sample(int bytes, Duration at) {
    _samples.add((at, bytes));
    while (_samples.length > 2 &&
        at - _samples.first.$1 > const Duration(seconds: 2)) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final dt = (at - first.$1).inMilliseconds;
    if (dt > 0) speed = (bytes - first.$2) * 1000 / dt;
  }
}
