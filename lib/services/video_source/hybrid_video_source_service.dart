import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/shared_http_client.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';
import 'package:miru/services/video_source/resolve_session.dart';
import 'package:miru/services/video_source/resolution_result_cache.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';
import 'package:miru/services/video_source/webview_video_source_service.dart';
import 'package:miru/utils/http_headers.dart';

/// 混合视频源解析服务：秒开链路的「调度层」。
///
/// 五级漏斗（v1.5.2），任何一级失败自动降级到下一级，任何情况下都能播：
///
/// 1. **本地解析缓存**（`ResolutionResultCache`）——同集二刷 0 解析时间；
/// 2. **本地快速解析**（`FastVideoSourceResolver`，阶段 0 重写为多候选
///    模型）——一次 GET 播放页提取最多 4 个候选（直链/解析器二跳/内联/
///    iframe），逐个探测取第一个通过者；
/// 3. **云端解析层**（`CloudVideoSourceResolver`，多端点并发竞速）；
/// 4. **WebView 嗅探**（兜底）。
///
/// 阶段 0 关键语义变化：
/// - **探测改「正向确认」**（§1.2）：alive 必须拿到内容证据
///   （#EXTM3U / ftyp / 0x47 同步字节），不再裸信 2xx；
///   `needsPositiveConfirm` 候选（无扩展名直链）的 unknown 视同 dead；
/// - **负缓存分级**（§1.3）：extractFailed → host 级 10min；
///   network → 不写；probeDead → URL 级 5min；
/// - **force**（用户显式重试）：忽略负缓存与短窗失败记忆；
/// - **连接复用**（§1.6）：探测/快解共用 SharedHttpClient；
/// - **清单 seed**（§1.2）：HLS 探测拿到的清单文本直接喂给代理，
///   预取/播放不再二次拉取同一 URL。
class HybridVideoSourceService implements IVideoSourceService {
  HybridVideoSourceService({WebViewVideoSourceService? webviewService})
      : _webviewService = webviewService ?? WebViewVideoSourceService();

  final WebViewVideoSourceService _webviewService;

  final ResolutionResultCache _cache = ResolutionResultCache.instance;
  final CloudVideoSourceResolver _cloud = CloudVideoSourceResolver.instance;
  final LocalMediaProxy _proxy = LocalMediaProxy.instance;
  final FastVideoSourceResolver _fast = FastVideoSourceResolver.instance;

  /// 直链可达性探测的超时（只影响「判定快慢」）。
  static const Duration probeTimeout = Duration(milliseconds: 1500);

  /// 探测连接阶段超时：黑洞主机（SYN 被丢，被墙 CDN 常态）硬顶。
  static const Duration probeConnectTimeout = Duration(milliseconds: 1500);

  /// 探测响应体读取限时（HLS 全量清单/非 HLS 首块）。清单只有几 KB，
  /// 3s 覆盖慢源首字节；超时按 unknown 处理（needsPositiveConfirm
  /// 候选视同 dead，见 §1.2 规则）。
  static const Duration probeBodyTimeout = Duration(seconds: 3);

  /// 解析缓存条目的「新鲜期」：写入后这么长时间内命中免探测。
  static const Duration freshEntryAge = Duration(minutes: 10);

  /// 短窗失败记忆：某层级失败后这么长时间内重试跳过该层级。
  /// （内存态；Hive 负缓存按 §1.3 分级，见 [_markLevelFailed]。）
  static const Duration levelRetryBackoff = Duration(seconds: 60);

  /// 负缓存键后缀（写入 ResolutionResultCache，跨进程生效）。
  static const String _fastLevelSuffix = '#fast';
  static const String _cloudLevelSuffix = '#cloud';

  /// URL 级短窗失败记忆：episodeUrl → 层级后缀 → 最近失败时间。
  final Map<String, Map<String, DateTime>> _levelFailures = {};

  /// 透传 WebView 解析日志（详情页解析日志面板用）。
  Stream<String> get onLog => _webviewService.onLog;

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return resolveWithHeaders(
      episodeUrl,
      useLegacyParser: useLegacyParser,
      offset: offset,
      timeout: timeout,
    );
  }

  /// 带播放请求头的解析（推荐入口）：探测/预取/代理回源都复用同一套
  /// headers，与 mpv 播放时完全一致，避免「探测可达但播放 403」。
  ///
  /// [prefetchEnabled] 置 false 时跳过后台预取与本地代理登记，仅供
  /// 下载路径使用。
  ///
  /// [force]（§1.3）：用户显式重试时传 true——忽略负缓存与短窗失败
  /// 记忆，且缓存命中不再免探测（重新验证）。
  Future<VideoSource> resolveWithHeaders(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 20),
    Map<String, String> playbackHeaders = const {},
    bool prefetchEnabled = true,
    bool force = false,
  }) async {
    final headers = _mergedPlaybackHeaders(playbackHeaders);

    // ---- 第 1 级：本地解析缓存 ----
    final cached = await _cache.get(episodeUrl);
    if (cached != null) {
      // 刚解析成功过的直链几乎不可能已失效：跳过探测，省一个 RTT。
      // force 时重新验证（用户显式重试就是不信这个结果）。
      final verdict = !force &&
              await _cache.isFresh(episodeUrl, freshEntryAge)
          ? _ProbeVerdict.alive
          : await _probe(cached.url, headers);
      if (verdict != _ProbeVerdict.dead) {
        MiruLogger().i(
            'HybridResolver: cache hit for $episodeUrl (${verdict.name})');
        return _materialize(cached, offset: offset, headers: headers,
            prefetchEnabled: prefetchEnabled);
      }

      // 明确的 4xx：直链已死（签名过期/防盗链），清除并继续走解析
      await _cache.invalidate(episodeUrl);
      MiruLogger()
          .w('HybridResolver: cached url is dead, re-resolving $episodeUrl');
    }

    // ---- 第 2/3/4 级：对冲竞速（阶段 2 / §2.2）----
    // 串行漏斗→波次竞速：t=0 fast（层内候选并发 3 探测）、
    // t=600ms cloud、t=1500ms webview；首个通过探测的产出者胜出，
    // 其余波次不再启动；硬上限 12s（用户 timeout 更小则尊重用户）。
    final hardDeadline = timeout < _raceHardDeadline ? timeout : _raceHardDeadline;
    final session = ResolveSession<VideoSource>(
      waves: {
        Duration.zero: (trace) =>
            _runFastLevel(episodeUrl, headers, force: force, trace: trace),
        const Duration(milliseconds: 600): (trace) =>
            _runCloudLevel(episodeUrl, headers, force: force, trace: trace),
        const Duration(milliseconds: 1500): (trace) =>
            _runWebViewLevel(
              episodeUrl,
              useLegacyParser: useLegacyParser,
              offset: offset,
              timeout: timeout,
              trace: trace,
            ),
      },
      hardDeadline: hardDeadline,
      onTrace: (trace) {
        final lines = trace.export().trim().split('\n');
        if (lines.isNotEmpty) {
          MiruLogger().d('HybridResolver: ${lines.last}');
        }
      },
    );
    _activeSessions.add(session);
    try {
      final winner = await session.run();
      return await _materialize(winner,
          offset: offset, headers: headers, prefetchEnabled: prefetchEnabled);
    } finally {
      _activeSessions.remove(session);
    }
  }

  /// 竞速硬上限（§2.2）：任何路径 12s，绝不无界等待。
  static const Duration _raceHardDeadline = Duration(seconds: 12);

  /// 进行中的竞速会话（cancel 用）。
  final Set<ResolveSession<VideoSource>> _activeSessions = {};

  /// 第 2 级：本地快速静态解析（多候选，阶段 0）→ 并发探测取首个
  /// 非 dead（阶段 2 / §2.3：原串行逐个探测最坏 4×1.5s=6s，
  /// 并发 3 后最坏 ≈ 1.5~3s）。
  Future<VideoSource?> _runFastLevel(
    String episodeUrl,
    Map<String, String> headers, {
    required bool force,
    required ResolveTrace trace,
  }) async {
    if (!force && await _shouldSkipLevel(episodeUrl, _fastLevelSuffix)) {
      trace.record(ResolveStage.fast, 'skipped', 'short-window failure');
      return null;
    }
    final report = await _fast.resolveCandidates(
      episodeUrl,
      userAgent: headers['user-agent'],
      referer: headers['referer'] ?? episodeUrl,
    );
    if (report.candidates.isEmpty) {
      trace.record(ResolveStage.fast, 'no-candidates',
          report.failure?.name);
      // 无候选：按失败分级记负缓存（network 不写，extractFailed host 级）
      await _markLevelFailed(episodeUrl, _fastLevelSuffix,
          report.failure ?? LevelFailureKind.extractFailed);
      return null;
    }
    trace.record(ResolveStage.fast, 'candidates',
        '${report.candidates.length} (${report.candidates.map((c) => c.strategy.name).join(',')})');
    final winner =
        await _firstAliveCandidate(report.candidates, headers);
    if (winner == null) {
      trace.record(ResolveStage.fast, 'all-dead', 'probe rejected all');
      // 全部候选探测判死：URL 级负缓存（仅本集，5min）
      await _markLevelFailed(
          episodeUrl, _fastLevelSuffix, LevelFailureKind.probeDead);
      return null;
    }
    trace.record(ResolveStage.fast, 'winner', winner.strategy.name);
    final source = winner.toVideoSource();
    await _cache.put(episodeUrl, source, ttl: ttlFor(source.url));
    _forgetLevelFailures(episodeUrl);
    return source;
  }

  /// 并发探测取首个非 dead 候选（§2.3 Verifier 并发 3）。
  Future<FastCandidate?> _firstAliveCandidate(
      List<FastCandidate> candidates, Map<String, String> headers) async {
    const concurrency = 3;
    final completer = Completer<FastCandidate?>();
    var cursor = 0;
    var finished = 0;
    Future<void> worker() async {
      while (true) {
        if (completer.isCompleted) return; // 已有胜者：不再浪费探测
        final i = cursor++;
        if (i >= candidates.length) return;
        final candidate = candidates[i];
        final probeHeaders = <String, String>{
          ...headers,
          if (candidate.referer.isNotEmpty)
            'referer': candidate.referer,
        };
        final verdict = await _probe(
          candidate.url,
          probeHeaders,
          needsPositiveConfirm: candidate.needsPositiveConfirm,
        );
        if (verdict != _ProbeVerdict.dead) {
          if (!completer.isCompleted) completer.complete(candidate);
          return;
        }
        finished++;
        if (finished >= candidates.length && !completer.isCompleted) {
          completer.complete(null);
        }
      }
    }

    unawaited(Future.wait(
      List.generate(concurrency.clamp(1, candidates.length), (_) => worker()),
    ));
    return completer.future;
  }

  /// 第 3 级：云端解析层 + 正向探测（产出即胜）。
  Future<VideoSource?> _runCloudLevel(
    String episodeUrl,
    Map<String, String> headers, {
    required bool force,
    required ResolveTrace trace,
  }) async {
    if (!_cloud.isConfigured) {
      trace.record(ResolveStage.cloud, 'not-configured');
      return null;
    }
    if (!force && await _shouldSkipLevel(episodeUrl, _cloudLevelSuffix)) {
      trace.record(ResolveStage.cloud, 'skipped', 'short-window failure');
      return null;
    }
    final cloudReport = await _cloud.resolveWithReport(
      episodeUrl,
      userAgent: headers['user-agent'],
      referer: headers['referer'],
    );
    final cloudResult = cloudReport.source;
    if (cloudResult == null) {
      trace.record(ResolveStage.cloud, 'no-source',
          cloudReport.failureClass);
      // 云端失败按分类分级：传输层故障不写负缓存（网络抖动不放大），
      // 站点级提取失败写 host 级（该站云端解不了，换站仍可用）。
      await _markLevelFailed(
          episodeUrl, _cloudLevelSuffix, _cloudFailureKind(cloudReport.failureClass));
      return null;
    }
    final needsConfirm =
        !FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
            cloudResult.url);
    final verdict = await _probe(cloudResult.url, headers,
        needsPositiveConfirm: needsConfirm);
    if (verdict == _ProbeVerdict.dead) {
      trace.record(ResolveStage.cloud, 'dead', 'probe rejected');
      await _markLevelFailed(
          episodeUrl, _cloudLevelSuffix, LevelFailureKind.probeDead);
      return null;
    }
    trace.record(ResolveStage.cloud, 'winner');
    await _cache.put(episodeUrl, cloudResult, ttl: ttlFor(cloudResult.url));
    _forgetLevelFailures(episodeUrl);
    return cloudResult;
  }

  /// 第 4 级：WebView 嗅探（兜底）。结果来自手机自己的会话，不做探测
  /// （v1.3.2 行为）。本层不记短窗失败——重试必须再给它机会。
  Future<VideoSource?> _runWebViewLevel(
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
    required ResolveTrace trace,
  }) async {
    trace.record(ResolveStage.webview, 'launched');
    final source = await _webviewService.resolve(
      episodeUrl,
      useLegacyParser: useLegacyParser,
      offset: offset,
      timeout: timeout,
    );
    await _cache.put(episodeUrl, source, ttl: ttlFor(source.url));
    _forgetLevelFailures(episodeUrl);
    trace.record(ResolveStage.webview, 'winner', 'sniffed');
    return source;
  }

  /// 云端失败分类 → 负缓存分级（§1.3）：
  /// 传输层/服务器 5xx → network（不写）；提取类 → extractFailed
  /// （host 级）；429/取消 → network 语义（不写持久负缓存：配额是
  /// 全局的、取消是用户主动的，负缓存都帮不上忙）。
  LevelFailureKind _cloudFailureKind(String? failureClass) {
    switch (failureClass) {
      case 'extract-failed':
      case 'bad-json':
      case 'invalid-url':
        return LevelFailureKind.extractFailed;
      default:
        // timeout / connect-error / bad-certificate / http-429 /
        // http-5xx / circuit-open / cancelled / error：不写持久负缓存
        return LevelFailureKind.network;
    }
  }

  /// 预解析（不抛异常、不打扰用户）：填解析缓存 + 预取开头数据。
  ///
  /// 使用场景：播放稳定后预解析下一集（换集接近秒开）。
  /// WebView 通道刻意跳过——预解析不该占用 WebView 实例。
  Future<void> prefetchResolve(String episodeUrl,
      {int offset = 0, Map<String, String> playbackHeaders = const {}}) async {
    if (episodeUrl.isEmpty) return;
    final headers = _mergedPlaybackHeaders(playbackHeaders);
    try {
      final cached = await _cache.get(episodeUrl);
      if (cached != null) {
        await _proxy.prefetch(
          cached.url,
          isHls: _isHls(cached),
          headers: headers,
        );
        return;
      }
      // 本地快解优先（不占 WebView、不等云端），失败再云端。
      final report = await _shouldSkipLevel(episodeUrl, _fastLevelSuffix)
          ? null
          : await _fast.resolveCandidates(
              episodeUrl,
              userAgent: headers['user-agent'],
              referer: headers['referer'] ?? episodeUrl,
            );
      VideoSource? result;
      if (report != null && report.candidates.isNotEmpty) {
        // 预解析用首个候选即可（探测留给正式播放，避免双倍探测流量）
        result = report.candidates.first.toVideoSource();
      }
      if (result == null &&
          _cloud.isConfigured &&
          !await _shouldSkipLevel(episodeUrl, _cloudLevelSuffix)) {
        final cloudReport = await _cloud.resolveWithReport(
          episodeUrl,
          userAgent: headers['user-agent'],
          referer: headers['referer'],
        );
        result = cloudReport.source;
      }
      if (result == null) return;
      await _cache.put(episodeUrl, result);
      await _proxy.prefetch(
        result.url,
        isHls: _isHls(result),
        headers: headers,
      );
      MiruLogger().i('HybridResolver: prefetch resolved $episodeUrl');
    } catch (e) {
      MiruLogger()
          .d('HybridResolver: prefetch failed for $episodeUrl', error: e);
    }
  }

  /// 播放失败后失效该集缓存（坏直链不再反复被用）。
  Future<void> invalidate(String episodeUrl) async {
    await _cache.invalidate(episodeUrl);
  }

  /// 为已解析好的直链补预取（缓存命中但数据未预取时）。
  Future<void> prefetchDataFor(VideoSource source,
      {Map<String, String> playbackHeaders = const {}}) async {
    await _proxy.prefetch(
      source.directUrl,
      isHls: _isHls(source),
      headers: _mergedPlaybackHeaders(playbackHeaders),
    );
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 把直链包装为最终给 mpv 的播放源。
  Future<VideoSource> _materialize(
    VideoSource source, {
    required int offset,
    required Map<String, String> headers,
    bool prefetchEnabled = true,
  }) async {
    final directUrl = source.url;
    final isHls = _isHls(source);

    final mergedHeaders = <String, String>{
      ...source.playbackHeaders,
      ...headers,
    };

    if (prefetchEnabled) {
      // 后台预取开头数据（不阻塞返回；计量网络下内部自动跳过）
      unawaited(
          _proxy.prefetch(directUrl, isHls: isHls, headers: mergedHeaders));

      final useProxy = _proxy.isEnabled &&
          await _proxy.hasUsableCache(directUrl, isHls: isHls);
      if (useProxy) {
        final proxyUrl = await _proxy.register(
          directUrl,
          isHls: isHls,
          headers: mergedHeaders,
        );
        if (proxyUrl != null) {
          return VideoSource(
            url: proxyUrl,
            offset: offset,
            type: source.type,
            format: source.format,
            directUrl: directUrl,
            playbackHeaders: mergedHeaders,
          );
        }
      }
    }
    return VideoSource(
      url: directUrl,
      offset: offset,
      type: source.type,
      format: source.format,
      directUrl: directUrl,
      playbackHeaders: mergedHeaders,
    );
  }

  Map<String, String> _mergedPlaybackHeaders(
      Map<String, String> playbackHeaders) {
    final headers = <String, String>{
      'user-agent': playbackHeaders['user-agent'] ?? getSessionUA(),
      if (playbackHeaders.containsKey('referer'))
        'referer': playbackHeaders['referer']!,
      if (playbackHeaders.containsKey('cookie'))
        'cookie': playbackHeaders['cookie']!,
    };
    return headers;
  }

  // -------------------------------------------------------------------------
  // 短窗失败记忆 + 分级负缓存（B15 / §1.3）
  // -------------------------------------------------------------------------

  /// 该层级是否应在本次重试中跳过：内存短窗记忆命中，或负缓存
  /// （URL 级 / host 级）命中。
  Future<bool> _shouldSkipLevel(String episodeUrl, String levelSuffix) async {
    final fails = _levelFailures[episodeUrl];
    final at = fails?[levelSuffix];
    if (at != null && DateTime.now().difference(at) < levelRetryBackoff) {
      return true;
    }
    if (await _cache.isNegative(episodeUrl + levelSuffix)) {
      return true;
    }
    // host 级负缓存（extractFailed）：同站任何一集的失败都会让
    // 整站跳过该层。
    final host = _hostOf(episodeUrl);
    if (host != null) {
      return _cache.isNegative(host + levelSuffix);
    }
    return false;
  }

  /// 记一次层级失败（内存短窗 + 按分级写 Hive 负缓存）：
  /// - [LevelFailureKind.extractFailed] → host 级，TTL 10min；
  /// - [LevelFailureKind.probeDead] → URL 级，TTL 5min；
  /// - [LevelFailureKind.network] → 只记内存短窗，不写负缓存。
  Future<void> _markLevelFailed(
      String episodeUrl, String levelSuffix, LevelFailureKind kind) async {
    final fails = _levelFailures.putIfAbsent(episodeUrl, () => {});
    fails[levelSuffix] = DateTime.now();
    // 防膨胀：条目过多时清理已过期的（同集 URL 数量有限，正常不会触）
    if (_levelFailures.length > 256) {
      final now = DateTime.now();
      _levelFailures.removeWhere((_, f) => f.values
          .every((t) => now.difference(t) >= levelRetryBackoff));
    }
    try {
      switch (kind) {
        case LevelFailureKind.extractFailed:
          final host = _hostOf(episodeUrl);
          if (host != null) {
            await _cache.putNegative(host + levelSuffix,
                ttl: ResolutionResultCache.extractFailedTtl);
          }
          break;
        case LevelFailureKind.probeDead:
          await _cache.putNegative(episodeUrl + levelSuffix,
              ttl: ResolutionResultCache.probeDeadTtl);
          break;
        case LevelFailureKind.network:
          break; // 网络抖动不写持久负缓存
      }
    } catch (_) {
      // 负缓存写失败不影响主流程
    }
  }

  /// 任一层成功后清掉该 URL 的失败记忆。
  void _forgetLevelFailures(String episodeUrl) {
    _levelFailures.remove(episodeUrl);
  }

  static String? _hostOf(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? null : host;
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 直链可达性探测（正向确认语义，§1.2）
  // -------------------------------------------------------------------------

  /// 直链可达性判定（三态 + 正向确认）。
  ///
  /// - **alive**：2xx 且拿到内容证据——HLS 正文以 #EXTM3U 开头；
  ///   非 HLS 的 Content-Type 为 video\*/mpegurl，或首字节含 ftyp/
  ///   0x47/FLV/EBML 媒体魔数；
  /// - **dead**：403/404/410/451，或 2xx 但 text/html 且无 #EXTM3U
  ///   （错误页伪装），或 needsPositiveConfirm 候选无法正向确认；
  /// - **unknown**：连接/读取超时、5xx——带视频扩展名的 URL 放行给
  ///   mpv（自己的重连自愈比瞎猜靠谱）；[needsPositiveConfirm] 的
  ///   unknown 视同 dead（§1.2 规则）。
  ///
  /// 连接复用共享池（§1.6）；HLS 探测确认的清单文本 seed 给
  /// LocalMediaProxy（预取/播放不再二次拉取）。
  Future<_ProbeVerdict> _probe(String url, Map<String, String> headers,
      {bool needsPositiveConfirm = false}) async {
    final isHls = _isHlsUrl(url);
    try {
      final client = SharedHttpClient.io;
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(probeConnectTimeout, onTimeout: () {
        throw TimeoutException('probe connect: $url', probeConnectTimeout);
      });
      headers.forEach(request.headers.set);
      if (!isHls) {
        // MP4 等大文件只取前 1KB；m3u8 索引本身只有几 KB，
        // 不发 Range（部分 CDN 对 Range 请求的响应行为不一致）。
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      }
      final response = await request.close().timeout(
          probeTimeout,
          onTimeout: () =>
              throw TimeoutException('probe head: $url', probeTimeout));
      final status = response.statusCode;

      if (status >= 200 && status < 300) {
        if (isHls) {
          return await _probeHls(response, url, headers,
              needsPositiveConfirm: needsPositiveConfirm);
        }
        return await _probeNonHls(response, url,
            needsPositiveConfirm: needsPositiveConfirm);
      }
      if (status == 403 || status == 404 || status == 410 || status == 451) {
        return _ProbeVerdict.dead;
      }
      // 401/429/5xx 等：不确定，按 §1.2 规则处理
      return _uncertain(needsPositiveConfirm);
    } catch (_) {
      return _uncertain(needsPositiveConfirm);
    }
  }

  _ProbeVerdict _uncertain(bool needsPositiveConfirm) {
    // needsPositiveConfirm：unknown 视同 dead（无媒体信号的 URL 必须
    // 拿到正向确认才允许进缓存）；带扩展名候选保持 unknown 放行。
    return needsPositiveConfirm ? _ProbeVerdict.dead : _ProbeVerdict.unknown;
  }

  /// HLS 探测：读全量清单（封顶 64KB）→ 校验 #EXTM3U → seed 代理。
  Future<_ProbeVerdict> _probeHls(HttpClientResponse response, String url,
      Map<String, String> headers,
      {required bool needsPositiveConfirm}) async {
    try {
      final bytes = await _readAll(response, 64 * 1024, probeBodyTimeout);
      if (bytes == null) {
        return _uncertain(needsPositiveConfirm);
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.isEmpty) {
        // 空响应：无法判定 → §1.2 规则
        return _uncertain(needsPositiveConfirm);
      }
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      final trimmed = text.trimLeft();
      if (!trimmed.startsWith('#EXTM3U')) {
        // 声称是 m3u8 的 URL 回了错误页/播放器页：判死，不进缓存
        return _ProbeVerdict.dead;
      }
      // alive：清单文本 seed 给代理（预取/播放零二次拉取）
      unawaited(_seedProxyManifest(url, trimmed, headers));
      return _ProbeVerdict.alive;
    } catch (_) {
      return _uncertain(needsPositiveConfirm);
    }
  }

  /// 非 HLS 探测：Content-Type + 首块字节魔数双重确认。
  Future<_ProbeVerdict> _probeNonHls(HttpClientResponse response, String url,
      {required bool needsPositiveConfirm}) async {
    try {
      final contentType = (response.headers
              .value(HttpHeaders.contentTypeHeader) ?? '')
          .toLowerCase();
      final firstChunk = await response.first
          .timeout(probeBodyTimeout)
          .catchError((_) => <int>[]);
      unawaited(response.drain<void>()
          .timeout(probeBodyTimeout)
          .catchError((_) {}));
      final hasExtension = _hasVideoExtension(url);
      final sniffed = _sniffMediaBytes(firstChunk);

      if (contentType.contains('text/html')) {
        // 2xx + text/html：错误页/播放器页伪装 → 判死（§1.2）
        return _ProbeVerdict.dead;
      }
      final stronglyVideo = contentType.startsWith('video/') ||
          contentType.startsWith('audio/') ||
          contentType.contains('mpegurl') ||
          contentType.contains('octet-stream') ||
          contentType.contains('binary');
      if (stronglyVideo) {
        if (sniffed) return _ProbeVerdict.alive;
        // 声称是视频但首块读不到/魔数不匹配：
        return _uncertain(needsPositiveConfirm || !hasExtension);
      }
      if (contentType.isEmpty) {
        if (sniffed) return _ProbeVerdict.alive;
        return _uncertain(needsPositiveConfirm || !hasExtension);
      }
      // 其他 content-type（json/text/plain…）：无扩展名 URL 视为错误页，
      // 带扩展名的放行（扩展名已是强信号，避免误杀）。
      return hasExtension
          ? _ProbeVerdict.unknown
          : _ProbeVerdict.dead;
    } catch (_) {
      return _uncertain(needsPositiveConfirm);
    }
  }

  /// 媒体字节魔数：mp4 ftyp（偏移 4）/ MPEG-TS 0x47 / FLV / EBML(mkv)。
  static bool _sniffMediaBytes(List<int> bytes) {
    if (bytes.length < 4) return false;
    if (bytes.length >= 8 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return true; // 'ftyp'
    }
    if (bytes[0] == 0x47) return true; // MPEG-TS sync byte
    if (bytes[0] == 0x46 && bytes[1] == 0x4C && bytes[2] == 0x56) {
      return true; // 'FLV'
    }
    if (bytes[0] == 0x1A && bytes[1] == 0x45) return true; // EBML
    return false;
  }

  Future<void> _seedProxyManifest(
      String url, String text, Map<String, String> headers) async {
    try {
      await _proxy.seedManifest(url, text, headers);
    } catch (_) {
      // seed 失败无碍：代理回退到自行拉取
    }
  }

  /// 读取整个响应体（封顶 [maxBytes]，总限时 [timeout]）。
  /// 超时/异常返回 null（区别于空 body 的空列表）。
  Future<List<int>?> _readAll(
      HttpClientResponse response, int maxBytes, Duration timeout) async {
    final bytes = <int>[];
    try {
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= maxBytes) break;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 常见视频直链扩展（与 FastVideoSourceResolver 一致）。
  static final RegExp _videoExtRe = RegExp(
      r'\.(m3u8|mp4|flv|ts|mkv|mov|webm)(?=$|[?#])',
      caseSensitive: false);

  bool _hasVideoExtension(String url) {
    final path = url.split('#').first.split('?').first;
    return _videoExtRe.hasMatch(path);
  }

  bool _isHls(VideoSource source) {
    return source.format == VideoSourceFormat.hls || _isHlsUrl(source.url);
  }

  bool _isHlsUrl(String url) {
    final path = url.split('#').first.split('?').first;
    // toLowerCase：大写 .M3U8 直链同样按 HLS 处理，与播放侧
    // _isHlsPlayback 的判定对齐，避免两侧语义漂移。
    return path.toLowerCase().endsWith('.m3u8');
  }

  @override
  void cancel() {
    // 阶段 2：先取消竞速会话（立即结束上层 await），再停 WebView。
    for (final session in _activeSessions.toList()) {
      session.cancel();
    }
    _activeSessions.clear();
    _webviewService.cancel();
  }

  @override
  Future<void> dispose() async {
    await _webviewService.dispose();
  }
}

/// 探测结论。
enum _ProbeVerdict {
  /// 2xx 且拿到内容证据（#EXTM3U / 媒体魔数）：直链健康。
  alive,

  /// 明确死亡：4xx(403/404/410/451)、2xx 错误页伪装、
  /// needsPositiveConfirm 候选无法正向确认。
  dead,

  /// 超时/网络抖动/5xx：带扩展名的候选放行给 mpv 自己处理。
  unknown,
}

/// 纯函数测试探针（阶段 0 单测）。
class HybridVideoSourceServiceProbe {
  /// 媒体字节魔数判定（ftyp / 0x47 / FLV / EBML）。
  static bool sniffMediaBytes(List<int> bytes) =>
      HybridVideoSourceService._sniffMediaBytes(bytes);
}
