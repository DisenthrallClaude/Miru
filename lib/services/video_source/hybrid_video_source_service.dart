import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';
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
/// 2. **本地快速解析**（`FastVideoSourceResolver`，v1.5.2 新增）——
///    手机直接 HTTP GET 播放页 + 静态提取（括号配平 player_aaaa +
///    MacCMS encrypt 解码 + 直链正则 + iframe 二跳），0.2~0.8 秒，
///    且出口 IP 与 mpv 播放一致（无防盗链绑定 IP 问题）；
/// 3. **云端解析层**（`CloudVideoSourceResolver`，多端点并发竞速）——
///    本地被拦（CF 盾/风控）时从 CF 边缘拉，1~3 秒返回直链；
/// 4. **WebView 嗅探**（原有逻辑原样保留）——JS 动态渲染/第三方
///    解析器型站点的最终兜底；
/// 5. 探测只做「三态判定」（见 [_ProbeVerdict]）：仅明确的 4xx 才判死，
///    超时/网络抖动一律放行给 mpv（v1.5.0 的二值探测把慢源误判成死链，
///    是「同一条规则有时顺有时不顺」的主要放大器）。
///
/// 失败止损：某层级失败后 60 秒内重试会跳过该层级
/// （内存短窗记忆 + ResolutionResultCache 负缓存），解析器翻转重试
/// 不再把快解/云端整层重跑一遍。
///
/// 拿到可用直链后：
/// - **智能代理**（v1.5.1）：磁盘已有该集开头数据才走本地代理（首帧从
///   磁盘秒出）；否则 mpv 直连源站——与 v1.3.2 完全一致的行为，代理从
///   「必经之路」退化成「纯加速器」，绝不给首播引入额外风险；
/// - 无论走不走代理，都在后台预取开头数据（MP4 4MB / HLS 前 6 分片），
///   为二刷和换集备好磁盘缓存。
///
/// 预解析（[prefetchResolve]）在「用户还没点播放」时把 1~3 级漏斗跑完
/// 并预取数据（播放稳定 8 秒后自动预解析下一集），点播放时整条链路已就绪。
class HybridVideoSourceService implements IVideoSourceService {
  HybridVideoSourceService({WebViewVideoSourceService? webviewService})
      : _webviewService = webviewService ?? WebViewVideoSourceService();

  final WebViewVideoSourceService _webviewService;

  final ResolutionResultCache _cache = ResolutionResultCache.instance;
  final CloudVideoSourceResolver _cloud = CloudVideoSourceResolver.instance;
  final LocalMediaProxy _proxy = LocalMediaProxy.instance;
  final FastVideoSourceResolver _fast = FastVideoSourceResolver.instance;

  /// 直链可达性探测的超时（只影响「判定快慢」，不影响正确性：
  /// 超时算 unknown，一律放行给 mpv 自己重试）。1.5s：探测串行在关键
  /// 路径上（弱网下健康源也常 >3s），三态判定下收紧是安全的——
  /// 只有明确的 403/404/410 才判死，其余全部放行（B16）。
  static const Duration probeTimeout = Duration(milliseconds: 1500);

  /// 探测连接阶段超时：黑洞主机（SYN 被丢，被墙 CDN 常态）会挂到
  /// OS 级 ~2 分钟，这里硬顶住（B1）。
  static const Duration probeConnectTimeout = Duration(milliseconds: 1500);

  /// 解析缓存条目的「新鲜期」：写入后这么长时间内命中免探测。
  static const Duration freshEntryAge = Duration(minutes: 10);

  /// 短窗失败记忆：某层级失败后这么长时间内重试跳过该层级。
  /// WebView 超时 → 解析器翻转重试时，刚失败过的快解/云端（其行为
  /// 与 useLegacyParser 无关）重跑纯烧时间（B15）。
  static const Duration levelRetryBackoff = Duration(seconds: 60);

  /// 负缓存键后缀（写入 ResolutionResultCache，TTL 60s，跨进程生效）。
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
    // 接口默认超时统一 20s（B7）：与 webview_video_source_service /
    // video_source_service 的签名默认对齐；实际播放路径由
    // video_controller 读 SettingsKeys.parseTimeout 设置后显式传入。
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
  Future<VideoSource> resolveWithHeaders(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 20),
    Map<String, String> playbackHeaders = const {},
  }) async {
    final headers = _mergedPlaybackHeaders(playbackHeaders);

    // ---- 第 1 级：本地解析缓存 ----
    final cached = await _cache.get(episodeUrl);
    if (cached != null) {
      // 刚解析成功过的直链几乎不可能已失效：跳过探测，省一个 RTT
      // （换集、切回刚看过的集、隔几分钟二刷都走这条零开销路径）。
      final verdict = await _cache.isFresh(episodeUrl, freshEntryAge)
          ? _ProbeVerdict.alive
          : await _probe(cached.url, headers);
      if (verdict != _ProbeVerdict.dead) {
        // alive（正常路径，+1 RTT）或 unknown（源站慢，交给 mpv 重试）
        MiruLogger().i(
            'HybridResolver: cache hit for $episodeUrl (${verdict.name})');
        return _materialize(cached, offset: offset, headers: headers);
      }

      // 明确的 4xx：直链已死（签名过期/防盗链），清除并继续走解析
      await _cache.invalidate(episodeUrl);
      MiruLogger()
          .w('HybridResolver: cached url is dead, re-resolving $episodeUrl');
    }

    // ---- 第 2 级：本地快速静态解析（v1.5.2）----
    // 手机直接 GET 播放页提取（MacCMS 通用结构），0.2~0.8 秒；
    // 出口 IP 与播放一致，拿到的直链没有「云端 IP 被防盗链拒掉」问题。
    // 短窗内刚失败过（或负缓存命中）则跳过本层（B15）。
    if (!await _shouldSkipLevel(episodeUrl, _fastLevelSuffix)) {
      final fastResult = await _fast.resolve(
        episodeUrl,
        userAgent: headers['user-agent'],
        referer: headers['referer'] ?? episodeUrl,
      );
      if (fastResult != null) {
        final verdict = await _probe(fastResult.url, headers);
        if (verdict != _ProbeVerdict.dead) {
          await _cache.put(episodeUrl, fastResult);
          _forgetLevelFailures(episodeUrl);
          return _materialize(fastResult, offset: offset, headers: headers);
        }
        MiruLogger()
            .w('HybridResolver: fast url rejected (dead), falling back');
      }
      // 快解失败/被拒：记短窗失败记忆 + 负缓存（TTL 60s），
      // 解析器翻转重试时不再重跑这一层。
      await _markLevelFailed(episodeUrl, _fastLevelSuffix);
    }

    // ---- 第 3 级：云端解析层 ----
    if (_cloud.isConfigured &&
        !await _shouldSkipLevel(episodeUrl, _cloudLevelSuffix)) {
      final cloudResult = await _cloud.resolve(
        episodeUrl,
        userAgent: headers['user-agent'],
        referer: headers['referer'],
      );
      if (cloudResult != null) {
        final verdict = await _probe(cloudResult.url, headers);
        // dead = Worker 出口 IP 拿到的直链对手机明确 403（防盗链绑定
        // IP）；unknown（超时/网络抖动）放行——mpv 有自己的重试。
        if (verdict != _ProbeVerdict.dead) {
          await _cache.put(episodeUrl, cloudResult);
          _forgetLevelFailures(episodeUrl);
          return _materialize(cloudResult, offset: offset, headers: headers);
        }
        MiruLogger().w(
            'HybridResolver: cloud url rejected (dead), falling back');
      }
      await _markLevelFailed(episodeUrl, _cloudLevelSuffix);
    }

    // ---- 第 4 级：WebView 嗅探（原有兜底）----
    // WebView 结果来自手机自己的会话，不做探测（v1.3.2 行为）：
    // 探测只会徒增一次 RTT，坏链交给 mpv 打开失败 → 直连兜底 → 换源提示。
    // 注意：本层不记短窗失败——解析器翻转改变的就是 WebView 的行为，
    // 重试必须再给它机会。
    final source = await _webviewService.resolve(
      episodeUrl,
      useLegacyParser: useLegacyParser,
      offset: offset,
      timeout: timeout,
    );
    await _cache.put(episodeUrl, source);
    _forgetLevelFailures(episodeUrl);
    return _materialize(source, offset: offset, headers: headers);
  }

  /// 预解析（不抛异常、不打扰用户）：填解析缓存 + 预取开头数据。
  ///
  /// 使用场景：播放稳定后预解析下一集（换集接近秒开）。
  /// WebView 通道刻意跳过——预解析不该占用 WebView 实例，
  /// 播放请求到来时才能立即接管。
  Future<void> prefetchResolve(String episodeUrl,
      {int offset = 0, Map<String, String> playbackHeaders = const {}}) async {
    if (episodeUrl.isEmpty) return;
    final headers = _mergedPlaybackHeaders(playbackHeaders);
    try {
      final cached = await _cache.get(episodeUrl);
      if (cached != null) {
        // 已有解析结果：只补数据预取（换设备回来/隔天二刷场景）
        await _proxy.prefetch(
          cached.url,
          isHls: _isHls(cached),
          headers: headers,
        );
        return;
      }
      // 本地快解优先（不占 WebView、不等云端），失败再云端；
      // 短窗内刚失败过的层级同样跳过（省电省时，不新增失败标记）
      var result = await _shouldSkipLevel(episodeUrl, _fastLevelSuffix)
          ? null
          : await _fast.resolve(
              episodeUrl,
              userAgent: headers['user-agent'],
              referer: headers['referer'] ?? episodeUrl,
            );
      if (result == null &&
          _cloud.isConfigured &&
          !await _shouldSkipLevel(episodeUrl, _cloudLevelSuffix)) {
        result = await _cloud.resolve(
          episodeUrl,
          userAgent: headers['user-agent'],
          referer: headers['referer'],
        );
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
  ///
  /// 智能代理（v1.5.1）：磁盘已有可用缓存（MP4 ≥1MB / HLS ≥2 分片）才走
  /// 代理——此时首帧从磁盘秒出；否则直连，行为与 v1.3.2 完全一致，
  /// 代理不再是单点故障。无论走哪条路，都补一发后台预取，
  /// 为二刷/换集备好数据。
  Future<VideoSource> _materialize(
    VideoSource source, {
    required int offset,
    required Map<String, String> headers,
  }) async {
    final directUrl = source.url;
    final isHls = _isHls(source);

    // 解析层确认的源站头（防盗链 referer）合并进播放头：
    // 插件声明的头（用户显式配置）优先，解析层补齐缺失项。
    final mergedHeaders = <String, String>{
      ...source.playbackHeaders,
      ...headers,
    };

    // 后台预取开头数据（不阻塞返回；计量网络下内部自动跳过）
    unawaited(
        _proxy.prefetch(directUrl, isHls: isHls, headers: mergedHeaders));

    final useProxy = _proxy.isEnabled &&
        await _proxy.hasUsableCache(directUrl, isHls: isHls);
    if (!useProxy) {
      return VideoSource(
        url: directUrl,
        offset: offset,
        type: source.type,
        format: source.format,
        directUrl: directUrl,
        playbackHeaders: mergedHeaders,
      );
    }
    final proxyUrl = await _proxy.register(
      directUrl,
      isHls: isHls,
      headers: mergedHeaders,
    );
    if (proxyUrl == null) {
      return VideoSource(
        url: directUrl,
        offset: offset,
        type: source.type,
        format: source.format,
        directUrl: directUrl,
        playbackHeaders: mergedHeaders,
      );
    }
    return VideoSource(
      url: proxyUrl,
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
  // 短窗失败记忆 + 负缓存（B15）
  // -------------------------------------------------------------------------

  /// 该层级是否应在本次重试中跳过：内存短窗记忆命中，或负缓存
  /// （TTL 60s）命中。两级叠加：内存跨不到进程重启，负缓存跨进程，
  /// TTL 都短，不会把「源暂时抖动」放大成长时间不可用。
  Future<bool> _shouldSkipLevel(String episodeUrl, String levelSuffix) async {
    final fails = _levelFailures[episodeUrl];
    final at = fails?[levelSuffix];
    if (at != null &&
        DateTime.now().difference(at) < levelRetryBackoff) {
      return true;
    }
    return _cache.isNegative(episodeUrl + levelSuffix);
  }

  /// 记一次层级失败（内存 + 负缓存）。
  Future<void> _markLevelFailed(String episodeUrl, String levelSuffix) async {
    final fails = _levelFailures.putIfAbsent(episodeUrl, () => {});
    fails[levelSuffix] = DateTime.now();
    // 防膨胀：条目过多时清理已过期的（同集 URL 数量有限，正常不会触）
    if (_levelFailures.length > 256) {
      final now = DateTime.now();
      _levelFailures.removeWhere((_, f) => f.values
          .every((t) => now.difference(t) >= levelRetryBackoff));
    }
    try {
      await _cache.putNegative(episodeUrl + levelSuffix);
    } catch (_) {
      // 负缓存写失败不影响主流程
    }
  }

  /// 任一层成功后清掉该 URL 的失败记忆。
  void _forgetLevelFailures(String episodeUrl) {
    _levelFailures.remove(episodeUrl);
  }

  // -------------------------------------------------------------------------
  // 直链可达性三态探测
  // -------------------------------------------------------------------------

  /// 直链可达性三态判定。
  ///
  /// v1.5.0 的二值探测（超时=死链）在源站抖动时会误杀好链：
  /// 缓存命中 → 误判 → 作废缓存 → 全量重新解析（5~30 秒），
  /// 用户观感就是「同一条规则有时顺有时不顺」。v1.5.1 改为：
  /// - **alive**：2xx（HLS 时额外验证响应体以 #EXTM3U 开头，校验
  ///   失败直接判死——不少源站对无效直链返回 200 + HTML 错误页，
  ///   只看状态码会把错误页当活链缓存 30 分钟反复喂给 mpv，B3）；
  /// - **dead**：明确的 403/404/410，或「无扩展名直链回 200 但
  ///   content-type 明确不是视频」（错误页/播放器页伪装，B11）；
  /// - **unknown**：超时/连接失败/5xx——源站慢或抽风，放行给 mpv，
  ///   mpv 的重连自愈（v1.3.1 加固）比我们瞎猜靠谱。
  Future<_ProbeVerdict> _probe(
      String url, Map<String, String> headers) async {
    final isHls = _isHlsUrl(url);
    // B1：连接阶段必须有硬超时——黑洞主机（SYN 被丢）会挂到 OS 级
    // ~2 分钟，是「无限转圈」的根因之一。
    final client = HttpClient()..connectionTimeout = probeConnectTimeout;
    try {
      final request =
          await client.getUrl(Uri.parse(url)).timeout(probeConnectTimeout);
      headers.forEach(request.headers.set);
      if (!isHls) {
        // MP4 等大文件只取前 1KB；m3u8 索引本身只有几 KB，
        // 不发 Range（部分 CDN 对 Range 请求的响应行为不一致）。
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      }
      final response = await request.close().timeout(probeTimeout);
      final status = response.statusCode;
      if (isHls && status >= 200 && status < 300) {
        // 读首块字节校验 #EXTM3U：strip BOM/首段空白后必须以 #EXTM3U
        // 开头，否则按 dead 处理（B3：校验失败返回 unknown 与 alive
        // 在下游完全等价，等于没校验）。
        final head = await response
            .first
            .timeout(probeTimeout)
            .catchError((_) => <int>[]);
        var text = utf8.decode(head, allowMalformed: true);
        await response.drain<void>().timeout(probeTimeout).catchError((_) {});
        if (text.isEmpty) {
          // 首块没读到（超时/空响应）：无法判定，放行给 mpv
          return _ProbeVerdict.unknown;
        }
        if (text.startsWith('\uFEFF')) text = text.substring(1);
        if (!text.trimLeft().startsWith('#EXTM3U')) {
          // 声称是 m3u8 的 URL 回了错误页/播放器页：判死，不进缓存
          return _ProbeVerdict.dead;
        }
        return _ProbeVerdict.alive;
      }
      // 消耗掉 body，复用连接
      await response.drain<void>().timeout(probeTimeout).catchError((_) {});
      if (status >= 200 && status < 300) {
        // 无扩展名直链（如 /play?token=...）只看状态码验不出错误页 200
        // （B11）：追加 content-type 校验，仅视频/二进制形态算活。
        // 带视频扩展名的 URL 不做此校验（扩展名已是强信号，避免误杀）。
        if (!_hasVideoExtension(url)) {
          final contentType =
              (response.headers.value(HttpHeaders.contentTypeHeader) ?? '')
                  .toLowerCase();
          final looksVideo = contentType.isEmpty ||
              contentType.startsWith('video/') ||
              contentType.startsWith('audio/') ||
              contentType.contains('octet-stream') ||
              contentType.contains('mpegurl') ||
              contentType.contains('binary');
          if (!looksVideo) {
            return _ProbeVerdict.dead;
          }
        }
        return _ProbeVerdict.alive;
      }
      if (status == 403 || status == 404 || status == 410) {
        return _ProbeVerdict.dead;
      }
      // 401/429/5xx 等：不确定，放行
      return _ProbeVerdict.unknown;
    } catch (_) {
      return _ProbeVerdict.unknown;
    } finally {
      client.close(force: true);
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
    return path.endsWith('.m3u8');
  }

  @override
  void cancel() {
    _webviewService.cancel();
  }

  @override
  Future<void> dispose() async {
    await _webviewService.dispose();
  }
}

/// 探测结论。
enum _ProbeVerdict {
  /// 2xx：直链健康。
  alive,

  /// 明确的 403/404/410：直链已死（签名过期/防盗链绑定 IP）。
  dead,

  /// 超时/网络抖动/5xx：不确定，放行给 mpv 自己处理。
  unknown,
}
