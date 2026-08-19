import 'dart:io';

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
        // 下载已经在 DownloadManager._downloadSegmentWithRetry 里按分片重试
        // （3 次 / 1s-3s-9s，且每次失败会清掉 .tmp）。再在传输层套一层重试会
        // 嵌套放大成上十次请求，还会让真实错误迟迟浮不上来；流式响应的中断
        // 也发生在 body 消费阶段，传输层拦截器根本抓不到。所以这里关掉。
        enableRetry: false,
      );

  static Dio createForConfig(NetworkConfig config) {
    // 目前唯一的调用方是代理测试页，要的就是「一次请求的真实结果」，
    // 不能靠重试把失败掩盖掉，也不该把测试时间拖长。
    return _create(config, enableRetry: false);
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
    bool enableRetry = true,
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
    // 重试放在链首：dio.fetch 会重跑整条 onRequest 链，镜像重写因此依然生效，
    // 且不会被二次重写（重写后的 host 已不在映射表里）。
    if (enableRetry) {
      dio.interceptors.add(_RetryInterceptor(dio));
    }
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

/// 网络层自动重试。
///
/// 仅对「明显可重试」的瞬时故障重试：连接/超时类错误、连接被重置、以及
/// 5xx 服务端错误。绝不重试 4xx（请求本身有问题）、证书错误和已取消的请求，
/// 避免把不可重试的失败放大成多次无谓请求。
///
/// 生效范围：apiDio / rulesRepoDio / pluginDio。
/// 明确排除 downloadDio（DownloadManager 自己已按分片重试）和
/// createForConfig（代理测试要看单次真实结果），见各自的注释。
///
/// 走到这里的请求要么是 GET，要么是语义上「幂等的设置/查询型」POST
/// （Bangumi 条目搜索、以图搜番、设置收藏状态），重放不会产生副作用。
///
/// 注意：真正的视频播放地址是在隐藏 WebView 里嗅探的，不走 Dio，因此本重试
/// 只提升「搜索 / 详情 / 弹幕 / 规则」这些请求的稳定性，不影响播放嗅探本身。
class _RetryInterceptor extends Interceptor {
  _RetryInterceptor(this._dio);

  final Dio _dio;

  static const _delays = <Duration>[
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final attempt = (err.requestOptions.extra['__retry_attempt'] as int?) ?? 0;
    final maxRetries = _maxRetriesFor(err);
    if (attempt >= maxRetries) {
      handler.next(err);
      return;
    }

    final delay =
        _delays[attempt < _delays.length ? attempt : _delays.length - 1];
    KazumiLogger().w(
        'Dio retry ${attempt + 1}/$maxRetries in ${delay.inMilliseconds}ms: '
        '${err.requestOptions.uri} (${err.type})');
    await Future.delayed(delay);

    final options = err.requestOptions;
    options.extra['__retry_attempt'] = attempt + 1;
    try {
      final response = await _dio.fetch(options);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  /// 0 表示不重试。
  ///
  /// 超时类错误每次重试都要再等满一个 timeout（默认 12s），所以只给 1 次，
  /// 避免搜索这类交互操作被拖到半分钟以上；快速失败的连接错误和 5xx 给 2 次。
  int _maxRetriesFor(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 1;
      case DioExceptionType.connectionError:
        return 2;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode ?? 0;
        return (status >= 500 && status < 600) ? 2 : 0;
      case DioExceptionType.unknown:
        // unknown 常常包着底层 socket 错误（连接被重置、GFW 干扰等），这类可重试；
        // 其余未知错误保持保守，不重试。
        return (err.error is SocketException || err.error is HttpException)
            ? 2
            : 0;
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
        return 0;
    }
  }
}
