import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/core/bangumi_proxy_router.dart';

void main() {
  group('BangumiProxyRouter', () {
    test('rewrites official api host to the community proxy first', () {
      final uri = Uri.parse('https://api.bgm.tv/v0/search/subjects?limit=20');
      expect(
        BangumiProxyRouter.rewrite(uri),
        'https://bgmapi.anibt.net/v0/search/subjects?limit=20',
      );
    });

    test('rewrites next.bgm.tv independently so the two backends stay unmixed',
        () {
      final uri = Uri.parse('https://next.bgm.tv/p1/subjects/153197');
      expect(
        BangumiProxyRouter.rewrite(uri),
        'https://next.bangumi.lol/p1/subjects/153197',
      );
    });

    test('last attempt falls back to the official host', () {
      final uri = Uri.parse('https://api.bgm.tv/v0/subjects/1');
      expect(BangumiProxyRouter.attemptCount(uri.host), 2);
      expect(
        BangumiProxyRouter.rewrite(uri, attempt: 1),
        'https://api.bgm.tv/v0/subjects/1',
      );
      expect(BangumiProxyRouter.rewrite(uri, attempt: 2), isNull);
    });

    test('unknown hosts are left untouched', () {
      final uri = Uri.parse('https://example.com/v0/subjects/1');
      expect(BangumiProxyRouter.rewrite(uri), isNull);
      expect(BangumiProxyRouter.attemptCount(uri.host), 1);
    });

    test('retries timeouts and 5xx / 403 / 429, but not cancel or 404', () {
      DioException err(DioExceptionType type, {int? status}) {
        return DioException(
          requestOptions: RequestOptions(path: '/'),
          type: type,
          response: status == null
              ? null
              : Response(
                  requestOptions: RequestOptions(path: '/'),
                  statusCode: status,
                ),
        );
      }

      expect(
        BangumiProxyRouter.isRetryableDio(
          err(DioExceptionType.connectionTimeout),
        ),
        isTrue,
      );
      expect(
        BangumiProxyRouter.isRetryableDio(
          err(DioExceptionType.badResponse, status: 502),
        ),
        isTrue,
      );
      expect(
        BangumiProxyRouter.isRetryableDio(
          err(DioExceptionType.badResponse, status: 403),
        ),
        isTrue,
      );
      expect(
        BangumiProxyRouter.isRetryableDio(
          err(DioExceptionType.badResponse, status: 429),
        ),
        isTrue,
      );
      expect(
        BangumiProxyRouter.isRetryableDio(
          err(DioExceptionType.badResponse, status: 404),
        ),
        isFalse,
      );
      expect(
        BangumiProxyRouter.isRetryableDio(err(DioExceptionType.cancel)),
        isFalse,
      );
    });
  });
}
