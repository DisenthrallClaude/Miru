import 'package:dio/dio.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/request/core/network_error_mapper.dart';
import 'package:miru/utils/http_headers.dart';

/// 规则站点抓取客户端。
///
/// User-Agent 采用「每站点粘性会话 UA」：同一 host 的所有请求在进程内
/// 复用首次随机生成的 UA——反反爬站点普遍把 clearance Cookie 与签发时的
/// UA 绑定，若每个请求都换随机 UA，即使带上 Cookie 也会被判为不同指纹
/// 而再次弹验证（验证死循环的成因之一）。规则显式指定的 UA 仍优先
/// （[requestText] 的 [headers] 展开在本默认值之后）。
class PluginSiteClient {
  PluginSiteClient._();

  static final PluginSiteClient instance = PluginSiteClient._();

  /// host → 本会话固定使用的 UA。
  final Map<String, String> _hostUserAgents = {};

  Future<String> requestText(
    String url, {
    required String method,
    Map<String, dynamic> headers = const {},
    Map<String, dynamic> queryParameters = const {},
    Object? data,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await DioFactory.pluginDio.request<String>(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          headers: _headers(url, headers),
        ),
        cancelToken: cancelToken,
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Map<String, dynamic> _headers(String url, Map<String, dynamic> headers) {
    // 调用方（规则引擎已统一小写化）自带 UA 时规则优先，不再注入默认值，
    // 避免 dio 发出两个大小写不同的 user-agent 头。
    final hasCallerUserAgent = headers.keys
        .any((key) => key.toLowerCase() == 'user-agent');
    return {
      if (!hasCallerUserAgent) 'user-agent': _stickyUserAgentFor(url),
      'Accept-Language': getRandomAcceptedLanguage(),
      'Connection': 'keep-alive',
      ...headers,
    };
  }

  /// 取该 host 的粘性 UA；首次访问时随机生成并固定复用。
  String _stickyUserAgentFor(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    if (host.isEmpty) return getRandomUA();
    return _hostUserAgents[host] ??= getRandomUA();
  }
}
