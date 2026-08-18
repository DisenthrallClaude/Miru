import 'package:dio/dio.dart';

/// Bangumi 官方 host → 社区反代的路由表。
///
/// 自建包拿不到 Kazumi mirror 密钥，只能走无需鉴权的公共反代。
/// 反代是个人维护的公共服务，可能限流或停服，因此每个官方 host
/// 都带一份有序候选：先反代，最后回落到官方域名（有代理/出国网络时可用）。
abstract final class BangumiProxyRouter {
  /// 官方 host 对应的反代基址，按优先级排列。
  static const hostProxies = <String, List<String>>{
    'api.bgm.tv': [
      'https://bgmapi.anibt.net',
    ],
    'next.bgm.tv': [
      'https://next.bangumi.lol',
    ],
  };

  /// 一次请求最多试几次：所有反代 + 官方原站。
  static int attemptCount(String host) {
    final proxies = hostProxies[host];
    if (proxies == null) return 1;
    return proxies.length + 1;
  }

  /// 把官方 URL 改写成第 [attempt] 个候选。
  ///
  /// * `attempt` 落在反代列表内 → 对应反代；
  /// * `attempt == 反代数` → 官方原站；
  /// * 超出范围或不是已知官方 host → `null`（调用方保持原 URL）。
  static String? rewrite(Uri uri, {int attempt = 0}) {
    if (attempt < 0) return null;
    final proxies = hostProxies[uri.host];
    if (proxies == null) return null;
    final suffix = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    if (attempt < proxies.length) {
      return proxies[attempt] + suffix;
    }
    if (attempt == proxies.length) {
      return '${uri.scheme}://${uri.host}$suffix';
    }
    return null;
  }

  /// 网络抖动、反代限流、网关挂掉才值得换下一个候选。
  /// 业务 4xx（除 403/429）不重试，避免把「条目不存在」打成多次请求。
  static bool isRetryableDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return false;
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode ?? 0;
        return code >= 500 || code == 403 || code == 429;
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.unknown:
        return true;
      default:
        return true;
    }
  }
}
