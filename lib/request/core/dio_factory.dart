import 'package:dio/dio.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/request/core/dio_logger_interceptor.dart';
import 'package:miru/request/core/network_config.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/http_headers.dart';

class DioFactory {
  DioFactory._();

  /// 请求级「禁用自动重试」标记（与重试拦截器的防二次重试标记同键）。
  ///
  /// 供自带失败处理语义的调用方使用：Bangumi 竞速两侧、竞速全败后的
  /// 单请求回退等。这些路径外层已有换源/回退逻辑，拦截器再叠一次
  /// 重试只会把最坏耗时翻倍（竞速×重试×回退三层叠加曾达 48s）。
  /// 每次返回新 map：拦截器会向 extra 原地写入计时字段，不能共享 const 实例。
  static Map<String, dynamic> noRetryExtra() => {'__retried': true};

  static Dio? _apiDio;
  static Dio? _rulesRepoDio;
  static Dio? _pluginDio;
  static Dio? _downloadDio;

  static Dio get apiDio => _apiDio ??= _create(
        NetworkConfig.fromSettings(),
        defaultHeaders: {
          'referer': '',
          'user-agent': getRandomUA(),
        },
      );

  static Dio get rulesRepoDio => _rulesRepoDio ??= _create(
        NetworkConfig.fromSettings(),
        defaultHeaders: {
          'user-agent': getRandomUA(),
        },
        interceptors: [_RulesMirrorInterceptor()],
      );

  static Dio get pluginDio => _pluginDio ??= _create(
        NetworkConfig.fromSettings(),
        defaultHeaders: {
          'user-agent': getSessionUA(),
          'accept-language': getRandomAcceptedLanguage(),
        },
      );

  static Dio get downloadDio => _downloadDio ??= _create(
        NetworkConfig.fromSettings(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
        defaultHeaders: {
          'user-agent': getSessionUA(),
        },
        // 下载通道不重试（兑现注释承诺）：大文件断流后应走分片续传/
        // 换源重试（auto_updater 已有候选源循环），整段重发毫无意义；
        // 云端解析 GET 也不再产生脱离 4s 外闸的后台重试副本（幽灵请求）。
        retry: false,
      );

  static Dio createForConfig(NetworkConfig config) {
    return _create(config);
  }

  /// 通用构建入口：让非单例调用方（如 GitHub 同步）也能走统一工厂——
  /// 读用户代理设置、统一超时、幂等 GET 单次自动重试一个不少。
  /// [validateStatus] 可覆盖默认的「仅 2xx」（GitHub 客户端需要 4xx
  /// 正常返回以便按状态码分流语义）。
  static Dio createDio({
    String? baseUrl,
    Map<String, dynamic> defaultHeaders = const {},
    List<Interceptor> interceptors = const [],
    bool retry = true,
    ValidateStatus? validateStatus,
    NetworkConfig? config,
  }) {
    return _create(
      config ?? NetworkConfig.fromSettings(),
      baseUrl: baseUrl,
      defaultHeaders: defaultHeaders,
      interceptors: interceptors,
      retry: retry,
      validateStatus: validateStatus,
    );
  }

  static void reset() {
    _apiDio = null;
    _rulesRepoDio = null;
    _pluginDio = null;
    _downloadDio = null;
  }

  static Dio _create(
    NetworkConfig config, {
    String? baseUrl,
    Map<String, dynamic> defaultHeaders = const {},
    List<Interceptor> interceptors = const [],
    bool retry = true,
    ValidateStatus? validateStatus,
  }) {
    // Keep the constructor tear-off form so the migration guard can flag
    // direct Dio construction outside this factory with a simple search.
    // ignore: unnecessary_constructor_name
    final dio = Dio.new(
      BaseOptions(
        baseUrl: baseUrl ?? '',
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        sendTimeout: config.sendTimeout,
        headers: defaultHeaders,
        validateStatus: validateStatus ??
            ((status) => status != null && status >= 200 && status < 300),
      ),
    );
    dio.httpClientAdapter = config.createAdapter();
    // 幂等 GET 的单次自动重试：连接抖动/瞬时 5xx 不再直接把失败
    // 抛给上层（在线播放链路此前完全零重试）。
    // 下载通道除外：大文件断流后应走分片续传，整段重下毫无意义。
    if (retry) {
      dio.interceptors.add(_IdempotentRetryInterceptor(dio));
    }
    dio.interceptors.addAll(interceptors);
    if (config.enableLog) {
      dio.interceptors.add(DioLoggerInterceptor());
    }
    return dio;
  }
}

/// 幂等请求的受限重试拦截器。
///
/// 只重试 **GET**（无副作用），只重试一次，且仅针对连接层故障与
/// 瞬时服务端错误；4xx（参数/鉴权问题）重试没有意义。
/// 复用宿主 Dio 发起重试，保留代理/adapter 配置；
/// extra 标记确保重试失败不会再次进入重试分支。
class _IdempotentRetryInterceptor extends Interceptor {
  _IdempotentRetryInterceptor(this._dio);

  final Dio _dio;

  bool _shouldRetry(DioException err) {
    if (err.requestOptions.method.toUpperCase() != 'GET') {
      return false;
    }
    if (err.requestOptions.extra['__retried'] == true) {
      return false;
    }
    return switch (err.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse =>
        err.response?.statusCode != null && err.response!.statusCode! >= 500,
      _ => false,
    };
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (!_shouldRetry(err)) {
      handler.next(err);
      return;
    }
    // 取消传导：若原 CancelToken 已被取消（竞速已分胜负/用户主动取消），
    // 直接放弃重试——否则重试副本会脱离取消链变成后台幽灵请求。
    final cancelToken = err.requestOptions.cancelToken;
    if (cancelToken != null && cancelToken.isCancelled) {
      handler.next(err);
      return;
    }
    // 拷贝而非原地修改：调用方持有的原 options 不被标记污染，
    // 复用同一 options 重发时不会被误判「已重试」。
    final options = err.requestOptions.copyWith(
      extra: {...err.requestOptions.extra, '__retried': true},
    );
    // copyWith 不保证携带 CancelToken（各 dio 版本行为不一致），显式重挂：
    // 竞速的「race settled」取消、下载取消必须能传导到重试副本。
    options.cancelToken = cancelToken;
    MiruLogger().w(
        'Network: retrying idempotent GET after '
        '${err.type.name} (${options.uri.host})');
    try {
      final response = await _dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    } catch (e) {
      handler.next(err);
    }
  }
}

class _RulesMirrorInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final enableGitProxy = GStorage.getSetting(SettingsKeys.enableGitProxy);
    if (!enableGitProxy) {
      handler.next(options);
      return;
    }

    final url = options.uri.toString();
    if (!url.startsWith(ApiEndpoints.pluginShop)) {
      handler.next(options);
      return;
    }

    final mirrored = ApiEndpoints.pluginShopMirror +
        url.substring(ApiEndpoints.pluginShop.length);
    MiruLogger().d('Rules mirror: $mirrored');
    options.path = mirrored;
    handler.next(options);
  }
}
