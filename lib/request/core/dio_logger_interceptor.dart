import 'package:dio/dio.dart';
import 'package:miru/services/logging/logger.dart';

class DioLoggerInterceptor extends Interceptor {
  static const _startedAtExtraKey = '_miruStartedAt';

  /// 日志脱敏（F26）：uid 是遥测匿名标识，不应以明文出现在控制台/
  /// logcat（中间代理与抓 log 的工具都可见），统一打码为 ***。
  static final RegExp _uidQueryPattern = RegExp(r'uid=[^&\s]*');

  String _logUri(RequestOptions options) {
    return options.uri.toString().replaceAllMapped(_uidQueryPattern,
        (match) => 'uid=***');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtExtraKey] = DateTime.now();
    MiruLogger().d('HTTP: --> ${options.method} ${_logUri(options)}');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final elapsed = _elapsed(response.requestOptions);
    MiruLogger().d(
      'HTTP: <-- ${response.statusCode} '
      '${response.requestOptions.method} ${_logUri(response.requestOptions)}'
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
      'HTTP: <-- $status ${err.requestOptions.method} ${_logUri(err.requestOptions)}'
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
