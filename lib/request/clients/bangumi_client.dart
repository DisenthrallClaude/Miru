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
///   任何单边故障都无感；
/// - **POST**：不能并发竞速（有副作用，可能重复执行），改为
///   官方优先、连接层失败（请求确定没到达）转镜像重试一次。
/// 开关关闭时全部直连官方（原行为）。
class BangumiClient {
  BangumiClient._();

  static final BangumiClient instance = BangumiClient._();

  /// 官方 host → 社区公共反代（无需鉴权；两个反代后端不同，不能混用）。
  static const Map<String, String> _hostMirrors = {
    'api.bgm.tv': ApiEndpoints.bangumiApiProxyDomain,
    'next.bgm.tv': ApiEndpoints.bangumiNextProxyDomain,
  };

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    CancelToken? cancelToken,
  }) async {
    final candidates = _getCandidateUrls(url);
    if (candidates.length > 1) {
      final data = await _raceGet(candidates,
          queryParameters: queryParameters,
          requiresAuth: requiresAuth,
          externalCancelToken: cancelToken);
      if (data != null) return data;
      // 全部失败：退回单请求路径，让其抛出真实异常（含错误映射）
    }
    try {
      final response = await DioFactory.apiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            requiresAuth: requiresAuth,
            url: url,
            method: 'GET',
          ),
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
    final fallback = _mirrorUrlFor(url);
    try {
      final response = await DioFactory.apiDio.post(
        url,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            requiresAuth: requiresAuth,
            url: url,
            method: 'POST',
            data: data,
          ),
        ),
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
            headers: _headers(
              requiresAuth: requiresAuth,
              url: url,
              method: 'POST',
              data: data,
            ),
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

  /// 并发竞速：任一候选先回 2xx 且有数据即胜出，其余取消；
  /// 全部失败返回 null（调用方退回单请求路径拿真实异常）。
  Future<dynamic> _raceGet(
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

    final completer = Completer<dynamic>();
    var pending = urls.length;
    for (final u in urls) {
      unawaited(
        DioFactory.apiDio
            .get(
              u,
              queryParameters: queryParameters,
              options: Options(
                headers: _headers(
                  requiresAuth: requiresAuth,
                  url: u,
                  method: 'GET',
                ),
              ),
              cancelToken: sideTokens[u],
            )
            .then((response) {
              final data = response.data;
              if (!completer.isCompleted && data != null) {
                completer.complete(data);
              }
            })
            .catchError((_) {})
            .whenComplete(() {
              pending -= 1;
              if (pending == 0 && !completer.isCompleted) {
                completer.complete(null);
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
    String method = 'GET',
    Object? data,
  }) {
    final headers = <String, dynamic>{...bangumiHTTPHeader};
    final bangumiSyncEnable =
        GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    final token = GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
    if ((requiresAuth || bangumiSyncEnable) && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }
}
