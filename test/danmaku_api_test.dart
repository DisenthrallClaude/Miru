import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/modules/danmaku/danmaku_search_response.dart';
import 'package:miru/request/apis/danmaku_api.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/services/storage/storage.dart';

/// 手动弹幕检索的回归锁（同步自上游 Kazumi c32db78 + 6c3c46c）：
/// - 端点必须是 /api/v2/search/episodes（旧 /search/anime 25 条封顶，
///   大 franchises 主系列被截断）
/// - query 必须带 anime 参数与 v2=true（旧引擎会把关键词折叠成单条）
/// - 新响应模型解析（animes / hasMore / typeDescription 空值兜底）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    const MethodChannel pathChannel =
        MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      switch (call.method) {
        case 'getApplicationSupportDirectory':
        case 'getApplicationDocumentsDirectory':
        case 'getTemporaryDirectory':
        case 'getApplicationCacheDirectory':
          return '/tmp/miru_danmaku_api_test';
      }
      return null;
    });
    await Hive.initFlutter('/tmp/miru_danmaku_api_test/hive');
    await GStorage.init();
  });

  group('DanmakuSearchResponse', () {
    test('解析 animes 列表与 hasMore', () {
      final response = DanmakuSearchResponse.fromJson({
        'animes': [
          {
            'animeId': 8001,
            'animeTitle': '名侦探柯南',
            'typeDescription': 'TV',
          },
          {
            'animeId': 8002,
            'animeTitle': '名侦探柯南：万圣节的新娘',
            'typeDescription': null,
          },
        ],
        'hasMore': true,
      });
      expect(response.animes, hasLength(2));
      expect(response.animes.first.animeId, 8001);
      expect(response.animes.first.animeTitle, '名侦探柯南');
      expect(response.animes.first.typeDescription, 'TV');
      expect(response.animes.last.typeDescription, '');
      expect(response.hasMore, isTrue);
    });

    test('typeDescription / hasMore 缺省兜底', () {
      final response = DanmakuSearchResponse.fromJson({
        'animes': [
          {'animeId': 3, 'animeTitle': '孤星人'},
        ],
      });
      expect(response.animes.single.animeTitle, '孤星人');
      expect(response.animes.single.typeDescription, '');
      expect(response.hasMore, isFalse);
    });

    test('空结果', () {
      final response = DanmakuSearchResponse.fromJson({
        'animes': <dynamic>[],
        'hasMore': false,
      });
      expect(response.animes, isEmpty);
    });
  });

  group('DanmakuApi.getDanmakuSearchResponse', () {
    test('请求 episodes 端点且带 anime 与 v2=true 参数', () async {
      final dio = DioFactory.apiDio;
      final originalAdapter = dio.httpClientAdapter;
      addTearDown(() => dio.httpClientAdapter = originalAdapter);

      RequestOptions? captured;
      dio.httpClientAdapter = _CannedAdapter((options) {
        captured = options;
        return {
          'animes': [
            {
              'animeId': 8001,
              'animeTitle': '名侦探柯南',
              'typeDescription': 'TV',
            },
          ],
          'hasMore': false,
        };
      });

      final response = await DanmakuApi.getDanmakuSearchResponse('柯南');

      expect(captured, isNotNull, reason: '请求应经过替换的 adapter');
      expect(captured!.uri.path, '/api/v2/search/episodes',
          reason: '旧 /api/v2/search/anime 端点 25 条封顶且折叠关键词，'
              '长篇番剧主系列检索不到');
      expect(captured!.queryParameters['anime'], '柯南');
      expect(captured!.queryParameters['v2'], 'true',
          reason: '不带 v2=true 时旧引擎会把关键词折叠成单条');

      expect(response.animes.single.animeId, 8001);
      expect(response.animes.single.animeTitle, '名侦探柯南');
      expect(response.animes.single.typeDescription, 'TV');
      expect(response.hasMore, isFalse);
    });
  });
}

/// 固定 JSON 响应的 dio 适配器，并捕获 RequestOptions 供断言。
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.responder);

  final Map<String, dynamic> Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final payload = jsonEncode(responder(options));
    return ResponseBody.fromString(
      payload,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
