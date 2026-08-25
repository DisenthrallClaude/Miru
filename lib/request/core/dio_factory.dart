import 'package:dio/dio.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/request/core/dio_logger_interceptor.dart';
import 'package:miru/request/core/network_config.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/http_headers.dart';

class DioFactory {
  DioFactory._();

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
        interceptors: [_BangumiMirrorInterceptor()],
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
      );

  static Dio createForConfig(NetworkConfig config) {
    return _create(config);
  }

  static void reset() {
    _apiDio = null;
    _rulesRepoDio = null;
    _pluginDio = null;
    _downloadDio = null;
  }

  static Dio _create(
    NetworkConfig config, {
    Map<String, dynamic> defaultHeaders = const {},
    List<Interceptor> interceptors = const [],
    bool retry = true,
  }) {
    // Keep the constructor tear-off form so the migration guard can flag
    // direct Dio construction outside this factory with a simple search.
    // ignore: unnecessary_constructor_name
    final dio = Dio.new(
      BaseOptions(
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        sendTimeout: config.sendTimeout,
        headers: defaultHeaders,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
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
    // 拷贝而非原地修改：调用方持有的原 options 不被标记污染，
    // 复用同一 options 重发时不会被误判「已重试」。
    final options = err.requestOptions.copyWith(
      extra: {...err.requestOptions.extra, '__retried': true},
    );
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

class _BangumiMirrorInterceptor extends Interceptor {
  /// 官方 host → 社区公共反代。
  ///
  /// 原先统一重写到 api.miru.fyi，但那个 mirror 需要 KAZUMI_APPID/KEY 签名，
  /// 自建包拿不到密钥，导致搜索/评论/热门/时间表全部 403。
  /// 这里改用无需鉴权的公共反代，并且按原始 host 分别映射
  /// （两个反代的后端不同，不能混用）。
  static const _hostProxies = <String, String>{
    'api.bgm.tv': ApiEndpoints.bangumiApiProxyDomain,
    'next.bgm.tv': ApiEndpoints.bangumiNextProxyDomain,
  };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final enableBangumiProxy =
        GStorage.getSetting(SettingsKeys.enableBangumiProxy);
    if (!enableBangumiProxy) {
      handler.next(options);
      return;
    }

    final uri = options.uri;
    final proxy = _hostProxies[uri.host];
    if (proxy == null) {
      handler.next(options);
      return;
    }

    // path 与 query 原样保留，只替换域名
    final mirrored =
        proxy + uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    MiruLogger().d('Bangumi proxy: $mirrored');
    options.path = mirrored;
    handler.next(options);
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
