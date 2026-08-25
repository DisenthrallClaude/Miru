import 'package:dio/dio.dart';
import 'package:miru/services/logging/logger.dart';

class DioLoggerInterceptor extends Interceptor {
  static const _startedAtExtraKey = '_miruStartedAt';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtExtraKey] = DateTime.now();
    MiruLogger().d('HTTP: --> ${options.method} ${options.uri}');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final elapsed = _elapsed(response.requestOptions);
    MiruLogger().d(
      'HTTP: <-- ${response.statusCode} '
      '${response.requestOptions.method} ${response.requestOptions.uri}'
      '${elapsed == null ? '' : ' ${elapsed}ms'}',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final elapsed = _elapsed(err.requestOptions);
    final statusCode = err.response?.statusCode;
    final status = statusCode == null ? err.type.name : statusCode.toString();
    MiruLogger().w(
      'HTTP: <-- $status ${err.requestOptions.method} ${err.requestOptions.uri}'
      '${elapsed == null ? '' : ' ${elapsed}ms'}',
      error: err.message,
    );
    handler.next(err);
  }

  int? _elapsed(RequestOptions options) {
    final startedAt = options.extra[_startedAtExtraKey];
    if (startedAt is! DateTime) {
      return null;
    }
    return DateTime.now().difference(startedAt).inMilliseconds;
  }
}
