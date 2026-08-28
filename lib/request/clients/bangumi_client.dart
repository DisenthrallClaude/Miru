import 'dart:async';

import 'package:dio/dio.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/request/core/network_error_mapper.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';

/// Bangumi API 客户端：官方 + 社区镜像多源竞速（v1.5.1）。
///
/// 背景：api.bgm.tv / next.bgm.tv 国内直连时好时坏，单一镜像
/// （bgmapi.anibt.net / next.bangumi.lol）也各有抖动——首页轮播、
/// 详情页「点了加载不出来」大多卡在这一层。
///
/// 策略（[SettingsKeys.enableBangumiProxy] 开启时）：
/// - **GET**：官方与镜像并发，先回 2xx 者胜出，其余当场取消——
///   任何单边故障都无感；竞速两侧单次快失败（不叠加拦截器重试），
///   最坏耗时压在 ≈24s（竞速 12s + 全败回退 12s）；
/// - **POST**：不能并发竞速（有副作用，可能重复执行），改为
///   官方优先、连接层失败（请求确定没到达）转镜像重试一次。
/// 开关关闭时全部直连官方（原行为）。
///
/// 安全（F3）：携带 Bearer Token 的请求只发官方域——镜像
/// bgmapi.anibt.net 是无需鉴权的社区公共反代，仅参与匿名请求，
/// 开启同步时 token 也不会再泄露给第三方。
class BangumiClient {
  BangumiClient._();

  static final BangumiClient instance = BangumiClient._();

  /// Bearer Token 只允许发往这些官方域。
  static const Set<String> _officialHosts = {'api.bgm.tv', 'next.bgm.tv'};

  /// 官方 host → 社区公共反代（无需鉴权）。
  ///
  /// v1.5.2：移除 next.bgm.tv → next.bangumi.lol 的映射——该镜像对
  /// 非浏览器 UA 一律返回 403（Cloudflare 盾），竞速不仅无效还浪费
  /// 一次请求。next 系接口（评论/角色/日历）改为官方单路直连；
  /// 详情主链路（getBangumiInfoByID）已切到 api.bgm.tv/v0，
  /// 继续享受官方 + bgmapi.anibt.net 双路竞速。
  static const Map<String, String> _hostMirrors = {
    'api.bgm.tv': ApiEndpoints.bangumiApiProxyDomain,
  };

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    CancelToken? cancelToken,
  }) async {
    final headers = _headers(requiresAuth: requiresAuth, url: url);
    final candidates = _getCandidateUrls(url);
    final raced = candidates.length > 1;
    if (raced) {
      final (won, data) = await _raceGet(
        candidates,
        queryParameters: queryParameters,
        requiresAuth: requiresAuth,
        externalCancelToken: cancelToken,
      );
      if (won) return data;
      // 全部失败：退回单请求路径，让其抛出真实异常（含错误映射）
    }
    try {
      final response = await DioFactory.apiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: headers,
          // 竞速全败后的回退只保留一次不带重试的尝试（F2）：竞速两侧
          // 已各试过一次，这里再叠拦截器重试会把最坏耗时推回 48s。
          // 镜像关闭/无镜像域的直连路径维持原有的单次自动重试。
          extra: raced ? DioFactory.noRetryExtra() : null,
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    CancelToken? cancelToken,
  }) async {
    final headers = _headers(requiresAuth: requiresAuth, url: url);
    // 鉴权 POST（收藏写入等）绝不转镜像（F3）：匿名镜像只会 401，
    // 还会把带 token 的写请求暴露给第三方；匿名 POST（如搜索）
    // 仍享受连接层失败转镜像的回退。
    final fallback = requiresAuth ? null : _mirrorUrlFor(url);
    try {
      final response = await DioFactory.apiDio.post(
        url,
        data: data,
        queryParameters: queryParameters,
        options: Options(headers: headers),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      // 连接层失败（请求未到达）且镜像可用 → 镜像重试一次；
      // 其余（4xx/5xx/超时后接收失败）按原样映射抛出。
      final retryable = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError;
      if (!retryable || fallback == null || _isCancelled(cancelToken)) {
        throw await NetworkErrorMapper.mapException(e);
      }
      MiruLogger()
          .w('BangumiClient: POST official unreachable, retrying via mirror');
      try {
        final response = await DioFactory.apiDio.post(
          fallback,
          data: data,
          queryParameters: queryParameters,
          options: Options(
            headers: _headers(requiresAuth: false, url: fallback),
          ),
          cancelToken: cancelToken,
        );
        return response.data;
      } on DioException catch (e2) {
        throw await NetworkErrorMapper.mapException(e2);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 多源竞速
  // ---------------------------------------------------------------------------

  /// 请求候选地址：镜像开关关闭时只有官方；开启时官方 + 对应镜像。
  List<String> _getCandidateUrls(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return [url];
    final mirror = _hostMirrors[uri.host];
    if (mirror == null) return [url];
    if (!GStorage.getSetting(SettingsKeys.enableBangumiProxy)) {
      return [url];
    }
    final mirrored =
        mirror + uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    // 官方放前面：两边同时 2xx 时优先官方（镜像偶尔有数据延迟）。
    return [url, mirrored];
  }

  String? _mirrorUrlFor(String url) {
    final candidates = _getCandidateUrls(url);
    return candidates.length > 1 ? candidates[1] : null;
  }

  bool _isCancelled(CancelToken? token) =>
      token != null && token.isCancelled;

  /// 并发竞速：任一候选先回 2xx 即胜出（空体也算，F19），其余取消；
  /// 全部失败返回 won=false（调用方退回单请求路径拿真实异常）。
  Future<(bool, dynamic)> _raceGet(
    List<String> urls, {
    Map<String, dynamic>? queryParameters,
    required bool requiresAuth,
    CancelToken? externalCancelToken,
  }) async {
    final sideTokens = {for (final u in urls) u: CancelToken()};
    // 外部取消 → 所有候选一起取消
    externalCancelToken?.whenCancel.then((reason) {
      for (final t in sideTokens.values) {
        t.cancel(reason);
      }
    });

    final completer = Completer<(bool, dynamic)>();
    var pending = urls.length;
    for (final u in urls) {
      unawaited(
        DioFactory.apiDio
            .get(
              u,
              queryParameters: queryParameters,
              options: Options(
                // _headers 按目标 URL 域名决定是否携带 Bearer（F3）：
                // 官方侧带 token，镜像侧自动剥离。
                headers: _headers(
                  requiresAuth: requiresAuth,
                  url: u,
                ),
                // 竞速两侧单次快失败（F2）：内嵌重试会把单侧最坏耗时
                // 翻倍，且重试副本曾脱离竞速取消链（幽灵请求）。
                extra: DioFactory.noRetryExtra(),
              ),
              cancelToken: sideTokens[u],
            )
            .then((response) {
              // apiDio 的 validateStatus 只放行 2xx；到这里即为胜。
              // 2xx 空体（204/合法空）也算胜，不再因 data==null
              // 误判全败再走回退长路（F19）。
              if (!completer.isCompleted) {
                completer.complete((true, response.data));
              }
            })
            .catchError((_) {})
            .whenComplete(() {
              pending -= 1;
              if (pending == 0 && !completer.isCompleted) {
                completer.complete((false, null));
              }
            }),
      );
    }

    final result = await completer.future;
    // 胜负已定（或全部失败）：取消仍在飞的候选
    for (final t in sideTokens.values) {
      if (!t.isCancelled) t.cancel('race settled');
    }
    return result;
  }

  Map<String, dynamic> _headers({
    required bool requiresAuth,
    String? url,
  }) {
    final headers = <String, dynamic>{...bangumiHTTPHeader};
    final bangumiSyncEnable =
        GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    final token = GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
    final wantsAuth = (requiresAuth || bangumiSyncEnable) && token.isNotEmpty;
    // Bearer 只发官方域（F3）：镜像等第三方域名一律剥离——镜像无需
    // 鉴权，把 token 发过去只会扩大泄露面（被入侵即可操作用户收藏）。
    if (wantsAuth && _isOfficialUrl(url)) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  bool _isOfficialUrl(String? url) {
    if (url == null) return false;
    final host = Uri.tryParse(url)?.host;
    return host != null && _officialHosts.contains(host);
  }
}
