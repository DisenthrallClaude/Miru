import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_logger_interceptor.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/http_headers.dart';

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
          'user-agent': getRandomUA(),
          'accept-language': getRandomAcceptedLanguage(),
        },
      );

  static Dio get downloadDio => _downloadDio ??= _create(
        NetworkConfig.fromSettings(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
        defaultHeaders: {
          'user-agent': getRandomUA(),
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
    dio.interceptors.addAll(interceptors);
    if (config.enableLog) {
      dio.interceptors.add(DioLoggerInterceptor());
    }
    return dio;
  }
}

class _BangumiMirrorInterceptor extends Interceptor {
  /// 官方 host → 社区公共反代。
  ///
  /// 原先统一重写到 api.kazumi.fyi，但那个 mirror 需要 KAZUMI_APPID/KEY 签名，
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
    KazumiLogger().d('Bangumi proxy: $mirrored');
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
    KazumiLogger().d('Rules mirror: $mirrored');
    options.path = mirrored;
    handler.next(options);
  }
}
