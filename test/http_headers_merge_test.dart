// v1.7.0（P0-6）：播放头合并规则回归锁。
//
// 验收（工单原文）：
// - plugin 带 cookie: cf_clearance=new，resolved 带
//   cookie: cf_clearance=old; a=1 → 合并结果 cf_clearance=new; a=1；
// - 缓存文件不应出现 cookie（resolution_result_cache_test 覆盖）；
// - referer 以解析层为准。
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/utils/http_headers.dart';

void main() {
  group('mergeCookieHeader：按 name 合并，high 覆盖同名', () {
    test('验收样例：cf_clearance=new 覆盖 old，a=1 保留', () {
      final merged =
          mergeCookieHeader('cf_clearance=new', 'cf_clearance=old; a=1');
      expect(merged, 'cf_clearance=new; a=1');
    });

    test('值中的 = 原样保留（base64 padding）', () {
      final merged = mergeCookieHeader('tok=abc==', 'x=1');
      expect(merged, 'x=1; tok=abc==');
    });

    test('无 = 的垃圾段跳过', () {
      final merged = mergeCookieHeader('a=1; ; junk; b=2', '');
      expect(merged, 'a=1; b=2');
    });

    test('空段与空值', () {
      expect(mergeCookieHeader('', 'a='), 'a=');
    });
  });

  group('mergePlaybackHeaders：插件侧 cookie 优先', () {
    test('双方都有 cookie：插件覆盖同名 + 保留解析层独有', () {
      final merged = mergePlaybackHeaders(
        {'user-agent': 'UA', 'cookie': 'cf_clearance=new'},
        {'referer': 'https://cdn.example.com/', 'cookie': 'cf_clearance=old; a=1'},
      );
      expect(merged['cookie'], 'cf_clearance=new; a=1');
      // referer 解析层优先。
      expect(merged['referer'], 'https://cdn.example.com/');
      expect(merged['user-agent'], 'UA');
    });

    test('只有插件有 cookie：原样保留', () {
      final merged = mergePlaybackHeaders(
        {'cookie': 'a=1'},
        {'referer': 'https://r/'},
      );
      expect(merged['cookie'], 'a=1');
    });

    test('只有解析层有 cookie（嗅探捕获的 CDN cookie）：保留', () {
      final merged = mergePlaybackHeaders(
        {'user-agent': 'UA'},
        {'cookie': 'cdn_sess=x'},
      );
      expect(merged['cookie'], 'cdn_sess=x');
    });

    test('都无 cookie：spread 语义不变', () {
      final merged = mergePlaybackHeaders(
        {'user-agent': 'UA', 'referer': 'https://plugin/'},
        {'referer': 'https://resolved/'},
      );
      expect(merged['referer'], 'https://resolved/');
      expect(merged.containsKey('cookie'), isFalse);
    });
  });
}
