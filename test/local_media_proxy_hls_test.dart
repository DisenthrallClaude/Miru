// LocalMediaProxy HLS 集成测试（真实回环 socket）。
//
// v1.6.8 修复项的回归锁（reviews/v168-agent-P2.md）：
// - R-3：带独立音轨组（EXT-X-MEDIA:TYPE=AUDIO + URI）的 master 走
//   audio 分支时，此前 segmentUrls 返回 const [] → 预取 0 片 →
//   hasUsableCache 永远 false → useProxy 门控使整条 P-10 改写链路
//   成为死代码、这类源完全失去分片缓存。现在必须：跟进首个视频
//   variant 子清单预取分片、meta 落 segTokens、hasUsableCache 可
//   满足、master 与音/视频子清单的 /m3u8/ 递归改写真正可达。
// - R-5：_forwardHeaders 旧白名单只有 UA/Referer——mpv 请求里带的
//   Cookie 被扔掉，cookie 门禁 CDN 走代理回源必 403 → 502 → 直连
//   兜底 churn。现在子清单/分段回源必须透传请求携带的 Cookie。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';

/// 与 LocalMediaProxy._tokenFor 相同的 sha1 前 10 字节 hex（测试镜像）。
String sha1Token(String url) {
  final digest = sha1.convert(utf8.encode(url));
  return digest.bytes
      .take(10)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// 分片内容确定性（按路径派生），供字节校验。
Uint8List segBytes(String path) {
  final seed = path.codeUnits.fold<int>(0, (a, b) => a + b);
  return Uint8List.fromList(
    List.generate(4096, (i) => (i * 31 + seed) % 251),
  );
}

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
        return '/tmp/miru_hls_test';
    }
    return null;
  });

  late HttpServer origin;
  /// 源站收到的请求头（path → 小写键名表），R-5 断言用。
  final originHeaders = <String, Map<String, String>>{};
  /// 源站收到的请求路径序列，R-3 预取断言用。
  final originRequestPaths = <String>[];

  const masterText = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="zh",URI="audio/track.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"
video/index.m3u8
''';

  /// v1.6.9（P0-4）回归素材：同时带音频组与字幕组的 master。
  /// 旧实现对所有含 URI= 的 EXT-X-MEDIA 行都改写成 /m3u8/ 清单代理
  /// ——字幕组的 WebVTT 清单被当 HLS 清单递归改写，外挂字幕加载
  /// 502/卡死。现在 SUBTITLES 的 URI 必须原样透传绝对地址。
  const masterWithSubsText = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="zh",URI="audio/track.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="字幕",DEFAULT=NO,AUTOSELECT=YES,LANGUAGE="zh",URI="subs/zh.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud",SUBTITLES="sub"
video/index.m3u8
''';

  // 8 个分片：预取只覆盖前 6（hlsPrefetchSegments），v-007 留作
  // 「未缓存分片的回源透传」测试素材。
  const videoPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXTINF:2.0,
v-001.ts
#EXTINF:2.0,
v-002.ts
#EXTINF:2.0,
v-003.ts
#EXTINF:2.0,
v-004.ts
#EXTINF:2.0,
v-005.ts
#EXTINF:2.0,
v-006.ts
#EXTINF:2.0,
v-007.ts
#EXTINF:2.0,
v-008.ts
#EXT-X-ENDLIST
''';

  const audioPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXTINF:2.0,
a-001.ts
#EXTINF:2.0,
a-002.ts
#EXTINF:2.0,
a-003.ts
#EXTINF:2.0,
a-004.ts
#EXT-X-ENDLIST
''';

  setUpAll(() async {
    Directory('/tmp/miru_hls_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_hls_test/hive');
    await GStorage.init();
    await GStorage.putSetting<bool>(
        SettingsKeys.localMediaCacheEnable, true);

    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final path = request.uri.path;
      originRequestPaths.add(path);
      final recorded = <String, String>{};
      request.headers.forEach((name, values) {
        recorded[name.toLowerCase()] = values.join('; ');
      });
      originHeaders[path] = recorded;

      switch (path) {
        case '/master.m3u8':
        case '/master_subs.m3u8':
        case '/video/index.m3u8':
        case '/audio/track.m3u8':
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.add(utf8.encode(switch (path) {
            '/master.m3u8' => masterText,
            '/master_subs.m3u8' => masterWithSubsText,
            '/video/index.m3u8' => videoPlaylist,
            _ => audioPlaylist,
          }));
          break;
        default:
          if (path.endsWith('.ts')) {
            final bytes = segBytes(path);
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await origin.close(force: true);
    await LocalMediaProxy.instance.shutdown();
  });

  String originUrl(String path) => 'http://127.0.0.1:${origin.port}$path';

  /// 通用响应体（字节）。
  Future<List<int>> getBodyBytes(String url,
      {Map<String, String>? headers}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers?.forEach(request.headers.set);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok,
          reason: 'GET $url 应返回 200');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// 清单类响应：读全文（文本）。
  Future<String> getBody(String url, {Map<String, String>? headers}) async {
    return utf8.decode(await getBodyBytes(url, headers: headers));
  }

  test('R-3: 音轨组 master 预取首个视频 variant 分片，hasUsableCache 可满足',
      () async {
    final master = originUrl('/master.m3u8');
    // 旧实现（segmentUrls: const []）下：预取 0 片 → hasUsableCache
    // 永远 false → useProxy 恒关，P-10 改写链路零调用。
    await LocalMediaProxy.instance.prefetch(master, isHls: true);

    // ① 跟进了第一个视频 variant 的子清单
    expect(originRequestPaths, contains('/video/index.m3u8'),
        reason: 'audio 分支必须跟进首个视频 variant 子清单（R-3）');
    // ② 预取了该 variant 的分片
    expect(originRequestPaths, contains('/video/v-001.ts'));
    expect(originRequestPaths, contains('/video/v-006.ts'));
    // ③ meta 落了 segTokens（hasUsableCache 的判据）
    final metaFile =
        File('/tmp/miru_hls_test/media_cache/${sha1Token(master)}.meta');
    expect(await metaFile.exists(), isTrue, reason: 'prefetch 应写入 meta');
    final meta =
        json.decode(await metaFile.readAsString()) as Map<String, dynamic>;
    expect((meta['s'] as List?) ?? [], isNotEmpty,
        reason: 'meta 必须登记 segTokens（R-3：旧实现永远为空）');
    // ④ hasUsableCache 从「永远 false」变为可满足
    expect(
      await LocalMediaProxy.instance.hasUsableCache(master, isHls: true),
      isTrue,
      reason: '≥2 个分片已落盘 → useProxy 门控放行（R-3 病灶：恒为 false）',
    );
  });

  test('R-3/R-5: master 与音/视频子清单走 /m3u8/ 递归代理，回源透传 Cookie',
      () async {
    const cookie = 'miru_sess=abc123; cf_clearance=test';
    final master = originUrl('/master.m3u8');
    await LocalMediaProxy.instance.prefetch(master, isHls: true);

    // ---- master 经代理：改写后的 EXT-X-MEDIA URI 与 variant 行都指向
    // /m3u8/ 代理 URL（P-10 改写链路真正可达）----
    final proxyMaster = (await LocalMediaProxy.instance
        .register(master, isHls: true, headers: const {}))!;
    final rewrittenMaster = await getBody(proxyMaster,
        headers: {HttpHeaders.cookieHeader: cookie});
    expect(rewrittenMaster, contains('#EXT-X-MEDIA'));

    final mediaLine = rewrittenMaster
        .split('\n')
        .firstWhere((l) => l.startsWith('#EXT-X-MEDIA'));
    final audioProxyUrl = RegExp('URI="([^"]+)"').firstMatch(mediaLine)!.group(1)!;
    expect(audioProxyUrl, startsWith('http://127.0.0.1:'));
    expect(audioProxyUrl, contains('/m3u8/'),
        reason: 'EXT-X-MEDIA 的音频 rendition URI 必须改写为 /m3u8/ 代理');

    final variantProxyUrl = rewrittenMaster.split('\n').firstWhere(
        (l) => l.trim().isNotEmpty && !l.startsWith('#'));
    expect(variantProxyUrl, startsWith('http://127.0.0.1:'));
    expect(variantProxyUrl, contains('/m3u8/'),
        reason: '视频 variant 行必须改写为 /m3u8/ 代理');

    // ---- 视频子清单经代理递归改写：分片 → /seg/；回源带 Cookie（R-5）----
    final rewrittenVideo = await getBody(variantProxyUrl,
        headers: {HttpHeaders.cookieHeader: cookie});
    expect(rewrittenVideo, contains('/seg/'),
        reason: '子清单分片必须改写为 /seg/ 代理 URL');
    final segProxyUrls = rewrittenVideo
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
        .toList();
    expect(segProxyUrls.length, 8, reason: '视频子清单应有 8 个分片');
    expect(
      originHeaders['/video/index.m3u8']?['cookie'],
      cookie,
      reason: '子清单回源必须透传 mpv 请求携带的 Cookie（R-5 病灶：被扔掉）',
    );

    // ---- 未预取的分片（v-007，第 7 片）经代理回源：透传 Cookie + 字节正确 ----
    final segBody = await getBodyBytes(segProxyUrls[6],
        headers: {HttpHeaders.cookieHeader: cookie});
    expect(segBody.length, 4096);
    expect(segBody, equals(segBytes('/video/v-007.ts')),
        reason: '分片内容必须与源站一致（透传链路不破坏数据）');
    expect(
      originHeaders['/video/v-007.ts']?['cookie'],
      cookie,
      reason: '分片回源必须透传 Cookie（R-5：/seg/ token 未注册，'
          '全靠 _forwardHeaders 透传）',
    );

    // ---- 音频 rendition 子清单同样经 /m3u8/ 递归改写 ----
    final rewrittenAudio = await getBody(audioProxyUrl,
        headers: {HttpHeaders.cookieHeader: cookie});
    expect(rewrittenAudio, contains('/seg/'),
        reason: '音频子清单分片必须改写为 /seg/ 代理 URL（P-10）');
    expect(
      originHeaders['/audio/track.m3u8']?['cookie'],
      cookie,
      reason: '音频子清单回源必须透传 Cookie（R-5）',
    );
  });

  test('P0-4: SUBTITLES 轨的 URI 原样透传，仅 AUDIO 走 /m3u8/ 代理',
      () async {
    final master = originUrl('/master_subs.m3u8');
    await LocalMediaProxy.instance.prefetch(master, isHls: true);
    final proxyMaster = (await LocalMediaProxy.instance
        .register(master, isHls: true, headers: const {}))!;
    final rewritten = await getBody(proxyMaster);

    final lines = rewritten.split('\n');
    final audioLine = lines.firstWhere(
        (l) => l.startsWith('#EXT-X-MEDIA') && l.contains('TYPE=AUDIO'));
    final subtitleLine = lines.firstWhere((l) =>
        l.startsWith('#EXT-X-MEDIA') && l.contains('TYPE=SUBTITLES'));

    // AUDIO rendition：URI 仍是 .m3u8 清单 → 改写为 /m3u8/ 递归代理。
    final audioUri =
        RegExp('URI="([^"]+)"').firstMatch(audioLine)!.group(1)!;
    expect(audioUri, startsWith('http://127.0.0.1:'));
    expect(audioUri, contains('/m3u8/'),
        reason: 'AUDIO rendition 的清单 URI 必须走 /m3u8/ 代理（P-10）');

    // SUBTITLES rendition：URI 必须是源站绝对地址（P0-4 病灶：
    // 旧实现把 WebVTT 字幕清单也改写成 HLS 清单代理 → 外挂字幕
    // 加载 502/卡死）。
    final subtitleUri =
        RegExp('URI="([^"]+)"').firstMatch(subtitleLine)!.group(1)!;
    expect(subtitleUri, originUrl('/subs/zh.m3u8'),
        reason: 'SUBTITLES 的 URI 必须原样透传绝对地址，不得进清单代理');
    // 源站与代理都在 127.0.0.1 上，用 /m3u8/ 代理路径段判别：
    // 透传地址不得携带代理清单路径（也不带 ?u= 注册参数）。
    expect(subtitleUri.contains('/m3u8/'), isFalse,
        reason: '字幕 URI 指向清单代理即 P0-4 回归');
    expect(subtitleUri.contains('?u='), isFalse,
        reason: '透传地址不得携带代理注册参数');
  });
}
