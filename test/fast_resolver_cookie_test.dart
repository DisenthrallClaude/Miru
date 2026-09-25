// v1.7.0（P0-8）：快解层插件 Cookie 透传（真回环 HttpServer 契约）。
//
// 验收（工单原文）：「本地假源站在没有 cookie 时返回 403、带 cookie
// 时返回含 player_aaaa 的 HTML，断言产出候选。」
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        return '/tmp/miru_p08_cookie_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_p08_cookie_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_p08_cookie_test/hive');
    await GStorage.init();
  });

  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 假源站：无 cookie → 403；带 cookie → player_aaaa 页面。
  void serveGuardedSite() {
    server.listen((request) async {
      final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
      if (!cookie.contains('cf_clearance=valid_token')) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
<html><body>
<script>
var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,
"link":"/video/ep01.m3u8","link_next":"","link_pre":"","url":"/video/ep01.m3u8",
"url_next":"","from":"mp4","server":"no","note":"","id":"1","sid":1,"nid":1}
</script>
</body></html>
''');
      await request.response.close();
    });
  }

  test('P0-8: 无 cookie 的快解请求被 403 拒（对照）', () async {
    serveGuardedSite();
    final pageUrl = 'http://127.0.0.1:${server.port}/play/1.html';
    final report =
        await FastVideoSourceResolver.instance.resolveCandidates(pageUrl);
    expect(report.candidates, isEmpty,
        reason: '验证类站点裸奔必 403——这正是 P0-8 要修的场景');
  });

  test('P0-8: 携带插件 cookie 后产出候选', () async {
    serveGuardedSite();
    final pageUrl = 'http://127.0.0.1:${server.port}/play/1.html';
    final report = await FastVideoSourceResolver.instance.resolveCandidates(
      pageUrl,
      extraHeaders: const {'cookie': 'cf_clearance=valid_token; theme=dark'},
    );
    expect(report.candidates, isNotEmpty,
        reason: '带 cookie 的快解请求应拿到 player_aaaa 页面并产出候选');
    final candidate = report.candidates.first;
    expect(candidate.url, contains('.m3u8'));
  });

  test('P0-8: 同可注册域判定（iframe/解析器二跳的 cookie 门控）', () {
    // 同域。
    expect(
      FastVideoSourceResolverCandidateProbe.sameRegistrableDomain(
          'https://www.a.com/x', 'https://a.com/y'),
      isTrue,
    );
    // 子域。
    expect(
      FastVideoSourceResolverCandidateProbe.sameRegistrableDomain(
          'https://cdn.a.com/x', 'https://www.a.com/y'),
      isTrue,
    );
    // 跨域。
    expect(
      FastVideoSourceResolverCandidateProbe.sameRegistrableDomain(
          'https://jx.other.com/api', 'https://www.a.com/y'),
      isFalse,
    );
  });
}
