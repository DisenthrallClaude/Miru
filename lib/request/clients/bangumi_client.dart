import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/bangumi_proxy_router.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';
import 'package:kazumi/utils/crypto.dart';

class BangumiClient {
  BangumiClient._();

  static final BangumiClient instance = BangumiClient._();

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    CancelToken? cancelToken,
  }) {
    return _withProxyFallback(
      url,
      (attempt) => DioFactory.apiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            requiresAuth: requiresAuth,
            url: url,
            method: 'GET',
          ),
          extra: {kBangumiProxyAttemptExtra: attempt},
        ),
        cancelToken: cancelToken,
      ),
    );
  }

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    CancelToken? cancelToken,
  }) {
    return _withProxyFallback(
      url,
      (attempt) => DioFactory.apiDio.post(
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
          extra: {kBangumiProxyAttemptExtra: attempt},
        ),
        cancelToken: cancelToken,
      ),
    );
  }

  /// 反代挂了就换下一个候选，最后打官方原站。
  Future<dynamic> _withProxyFallback(
    String url,
    Future<Response<dynamic>> Function(int attempt) send,
  ) async {
    final attempts = _attemptCount(url);
    DioException? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final response = await send(attempt);
        return response.data;
      } on DioException catch (e) {
        lastError = e;
        final canRetry =
            attempt < attempts - 1 && BangumiProxyRouter.isRetryableDio(e);
        if (!canRetry) {
          throw await NetworkErrorMapper.mapException(e);
        }
        KazumiLogger().w(
          'Bangumi: attempt $attempt failed, trying next endpoint',
          error: e,
        );
      }
    }
    throw await NetworkErrorMapper.mapException(
      lastError ??
          DioException(
            requestOptions: RequestOptions(path: url),
          ),
    );
  }

  int _attemptCount(String url) {
    if (!GStorage.getSetting(SettingsKeys.enableBangumiProxy)) {
      return 1;
    }
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return 1;
    return BangumiProxyRouter.attemptCount(host);
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
    if (_shouldSignProtectedMirrorRequest(url, method)) {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final body = data == null ? '' : jsonEncode(data);
      headers['X-AppId'] = bangumiMirrorCredentials['id'];
      headers['X-Timestamp'] = timestamp;
      headers['X-Signature'] = generateBangumiMirrorSearchSignature(
        method: method,
        path: Uri.parse(url!).path,
        body: body,
        timestamp: timestamp,
      );
    }
    return headers;
  }

  /// 是否需要给请求附带 Kazumi mirror 的签名头。
  ///
  /// 现在统一走无需鉴权的社区公共反代（见 `_BangumiMirrorInterceptor`），
  /// 因此恒为 false。保留此方法只是为了不打散 `_headers` 的结构，
  /// 将来若恢复自建 mirror，把判断逻辑放回这里即可。
  bool _shouldSignProtectedMirrorRequest(String? url, String method) {
    return false;
  }
}
