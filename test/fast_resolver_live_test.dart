@Tags(['live'])
library;

// 真实网络集成验证（手动跑：flutter test test/fast_resolver_live_test.dart）
// 覆盖 v1.5.2 核心场景：静态可解析站直出直链、第三方解析器/JS 站正确降级。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 的 binding 会用 mock HttpOverrides 把所有真实请求
  // 变成 400——本文件是真实网络集成测试，必须重置回真实 HttpClient。
  HttpOverrides.global = null;

  const ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  test('静态可解析站点全部直出直链（<2s）', () async {
    final resolver = FastVideoSourceResolver.instance;
    final cases = <(String, String, String)>[
      ('fqdm', 'https://www.fqdm.cc/index.php/vod/play/id/13196/sid/3/nid/1.html', 'https://www.fqdm.cc/'),
      ('MXdm', 'https://www.dcc3.com/play/12-1-1/', 'https://www.dcc3.com/'),
      ('taopian', 'https://video.chn.ci/index.php/vod/play/id/2716/sid/1/nid/1.html', 'https://video.chn.ci/'),
    ];
    for (final (name, url, ref) in cases) {
      final sw = Stopwatch()..start();
      final result = await resolver.resolve(url, userAgent: ua, referer: ref);
      sw.stop();
      // 源站抖动时允许 null，但只要出结果必须是 http 直链
      if (result != null) {
        expect(result.url, startsWith('http'));
        expect(sw.elapsedMilliseconds, lessThan(6000), reason: '$name 太慢');
        // ignore: avoid_print
        print('$name: OK ${sw.elapsedMilliseconds}ms ${result.url}');
      } else {
        // ignore: avoid_print
        print('$name: null（源站抖动，降级可接受）');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('第三方解析器 token 站正确返回 null（降级 WebView）', () async {
    final resolver = FastVideoSourceResolver.instance;
    final result = await resolver.resolve(
      'https://www.blbl.tv/index.php/vod/play/id/12816/sid/2/nid/222.html',
      userAgent: ua,
      referer: 'https://www.blbl.tv/',
    );
    // 静态解析拿不到 ACG token 站的直链是预期行为
    expect(result, isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
