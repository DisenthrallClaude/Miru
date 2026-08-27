import 'dart:async';
import 'dart:io';

import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';
import 'package:miru/services/video_source/resolution_result_cache.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';
import 'package:miru/services/video_source/webview_video_source_service.dart';
import 'package:miru/utils/http_headers.dart';

/// 混合视频源解析服务：秒开链路的「调度层」。
///
/// 把原先单一的 WebView 嗅探（5~30 秒）升级为四级漏斗，任何一级
/// 失败自动降级到下一级，任何情况下都能播：
///
/// 1. **本地解析缓存**（`ResolutionResultCache`）——同集二刷 0 解析时间；
/// 2. **云端解析层**（`CloudVideoSourceResolver`，多端点并发竞速）——
///    1~3 秒返回直链；
/// 3. **WebView 嗅探**（原有逻辑原样保留）——最终兜底；
/// 4. 每级成功后都过一遍**可达性探测**（Range 0-1024 / 清单首字节），
///    死链/防盗链绑定 IP 的结果当场丢弃，绝不把坏结果交给 mpv。
///
/// 拿到可用直链后注册**本地媒体代理**（`LocalMediaProxy`）并后台预取
/// 开头数据，mpv 播的是 `127.0.0.1` 的代理地址——首帧从磁盘秒出。
///
/// 预解析（[prefetchResolve]）在「用户还没点播放」时就把 1~3 级漏斗
/// 跑完并预取数据：进入详情页即预解析当前集、播放稳定后预解析下一集，
/// 点播放时整条链路已就绪。
class HybridVideoSourceService implements IVideoSourceService {
  HybridVideoSourceService({WebViewVideoSourceService? webviewService})
      : _webviewService = webviewService ?? WebViewVideoSourceService();

  final WebViewVideoSourceService _webviewService;

  final ResolutionResultCache _cache = ResolutionResultCache.instance;
  final CloudVideoSourceResolver _cloud = CloudVideoSourceResolver.instance;
  final LocalMediaProxy _proxy = LocalMediaProxy.instance;

  /// 直链可达性探测的超时。
  static const Duration probeTimeout = Duration(seconds: 3);

  /// 透传 WebView 解析日志（详情页解析日志面板用）。
  Stream<String> get onLog => _webviewService.onLog;

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 30),
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
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> playbackHeaders = const {},
  }) async {
    final headers = _mergedPlaybackHeaders(playbackHeaders);

    // ---- 第 1 级：本地解析缓存 ----
    final cached = await _cache.get(episodeUrl);
    if (cached != null) {
      if (await _isPlayable(cached.url, headers)) {
        MiruLogger().i('HybridResolver: cache hit for $episodeUrl');
        return _materialize(cached, offset: offset, headers: headers);
      }
      // 缓存的直链已失效（签名过期等），清除并继续走解析
      await _cache.invalidate(episodeUrl);
      MiruLogger()
          .w('HybridResolver: cached url is dead, re-resolving $episodeUrl');
    }

    // ---- 第 2 级：云端解析层 ----
    if (_cloud.isConfigured) {
      final cloudResult = await _cloud.resolve(
        episodeUrl,
        userAgent: headers['user-agent'],
        referer: headers['referer'],
      );
      if (cloudResult != null) {
        if (await _isPlayable(cloudResult.url, headers)) {
          await _cache.put(episodeUrl, cloudResult);
          return _materialize(cloudResult, offset: offset, headers: headers);
        }
        // Worker 出口 IP 拿到的直链对手机不可用（防盗链绑定 IP），丢弃
        MiruLogger().w(
            'HybridResolver: cloud url not playable on this device, falling back');
      }
    }

    // ---- 第 3 级：WebView 嗅探（原有兜底） ----
    final source = await _webviewService.resolve(
      episodeUrl,
      useLegacyParser: useLegacyParser,
      offset: offset,
      timeout: timeout,
    );
    await _cache.put(episodeUrl, source);
    return _materialize(source, offset: offset, headers: headers);
  }

  /// 预解析（不抛异常、不打扰用户）：填解析缓存 + 预取开头数据。
  ///
  /// 使用场景：进入详情页预解析当前集；播放稳定后预解析下一集。
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
      if (!_cloud.isConfigured) return;
      final cloudResult = await _cloud.resolve(
        episodeUrl,
        userAgent: headers['user-agent'],
        referer: headers['referer'],
      );
      if (cloudResult == null) return;
      await _cache.put(episodeUrl, cloudResult);
      await _proxy.prefetch(
        cloudResult.url,
        isHls: _isHls(cloudResult),
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

  /// 把直链包装为最终给 mpv 的播放源：优先本地代理，失败用直连。
  Future<VideoSource> _materialize(
    VideoSource source, {
    required int offset,
    required Map<String, String> headers,
  }) async {
    final directUrl = source.url;
    final proxyUrl = await _proxy.register(
      directUrl,
      isHls: _isHls(source),
      headers: headers,
    );
    if (proxyUrl == null) {
      return VideoSource(
        url: directUrl,
        offset: offset,
        type: source.type,
        format: source.format,
        directUrl: directUrl,
      );
    }
    return VideoSource(
      url: proxyUrl,
      offset: offset,
      type: source.type,
      format: source.format,
      directUrl: directUrl,
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

  /// 直链可达性探测：m3u8 拉清单首字节；其余 Range 0-1023。
  /// 任何非 2xx / 超时 / 异常都视为不可用。
  Future<bool> _isPlayable(String url, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      if (!_isHlsUrl(url)) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      }
      final response = await request.close().timeout(probeTimeout);
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      // 消耗掉 body，复用连接
      await response.drain<void>().timeout(probeTimeout).catchError((_) {});
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
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
