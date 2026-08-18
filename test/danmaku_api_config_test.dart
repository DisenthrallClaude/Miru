import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/danmaku_api_config.dart';

void main() {
  group('DanmakuApiConfig', () {
    test('empty input falls back to the official domain', () {
      expect(
        DanmakuApiConfig.resolveBaseUrl(''),
        'https://api.dandanplay.net',
      );
      expect(DanmakuApiConfig.resolveBaseUrl('   '), 'https://api.dandanplay.net');
    });

    test('normalizes scheme, trailing slash and /api/v2 suffix', () {
      expect(
        DanmakuApiConfig.resolveBaseUrl('danmu.example.com/87654321/'),
        'https://danmu.example.com/87654321',
      );
      expect(
        DanmakuApiConfig.resolveBaseUrl(
          'https://danmu.example.com/87654321/api/v2',
        ),
        'https://danmu.example.com/87654321',
      );
    });

    test('only official dandanplay requests need a signature', () {
      expect(
        DanmakuApiConfig.shouldSignRequest(
          'https://api.dandanplay.net/api/v2/comment/1',
        ),
        isTrue,
      );
      expect(
        DanmakuApiConfig.shouldSignRequest(
          'https://danmu.example.com/87654321/api/v2/comment/1',
        ),
        isFalse,
      );
    });
  });
}
