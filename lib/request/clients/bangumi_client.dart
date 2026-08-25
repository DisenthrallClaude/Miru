
import 'package:dio/dio.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/request/core/network_error_mapper.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/services/storage/storage.dart';

class BangumiClient {
  BangumiClient._();

  static final BangumiClient instance = BangumiClient._();

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    CancelToken? cancelToken,
  }) async {
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
      throw await NetworkErrorMapper.mapException(e);
    }
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
