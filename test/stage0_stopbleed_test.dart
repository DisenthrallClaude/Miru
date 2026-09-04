import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';
import 'package:miru/services/video_source/hybrid_video_source_service.dart';
import 'package:miru/services/video_source/resolution_result_cache.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';
import 'package:miru/webview/video/impl/video_webview_android_impl.dart';

/// 阶段 0（止血修复）单测（§1.8 验收清单）：
/// 1. player_aaaa from=xxjx 不再产出「直链」（isThirdPartyParser 分流）；
/// 2. needsPositiveConfirm（无扩展名候选）的探测超时语义 = dead；
/// 3. 负缓存三种 kind 的 TTL 行为（extractFailed host 级 /
///    probeDead URL 级 / network 不写）；
/// 4. 云端端点健康持久化（Hive 读写 + 熔断跳过不可达端点）。
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
        return '/tmp/miru_stage0_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_stage0_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_stage0_test/hive');
    await GStorage.init();
  });

  group('§1.1(b) 第三方解析器分流', () {
    test('from=xxjx 命中解析器名单（url 不再当直链）', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'xxjx', 'https://jx.example.com/?url=abc'),
          isTrue);
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'JsonJX', 'https://jx.example.com/?url=abc'),
          isTrue);
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'iqiyi', 'https://www.iqiyi.com/x'),
          isTrue);
    });

    test('from=m3u8 直链型站点不误判', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'ffm3u8', 'https://vip.example.com/index.m3u8'),
          isFalse);
      // 'le' 是包含匹配，但 from='player' 不含名单词
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'selfplayer', 'https://cdn.x.com/v.m3u8'),
          isFalse);
    });

    test('非 http 开头且无媒体扩展 = 解析器 token（ACG 形态）', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'ACG', 'ACG-43a311b473bc51884a9c7353d9e5bad8'),
          isTrue);
      // 站内绝对路径（/api.php 形态）由 from 判定，url 本身不背锅
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              null, '/vod/x.m3u8'),
          isFalse);
    });

    test('extractFull 带回 from 字段（二跳的输入）', () {
      final html =
          '<script>var player_aaaa={"flag":"play","encrypt":0,'
          '"url":"ACG-43a311b473bc51884a9c7353d9e5bad8","from":"ACG"};</script>';
      final result = FastVideoSourceResolverCandidateProbe.extractFull(html);
      expect(result, isNotNull);
      expect(result!.$1, 'ACG-43a311b473bc51884a9c7353d9e5bad8');
      expect(result.$3, 'ACG');
    });

    test('旧探词语义保留：非直链 token 仍返回 null（不破坏既有测试契约）',
        () {
      final html =
          '<script>var player_aaaa={"flag":"play","encrypt":0,'
          '"url":"ACG-43a311b473bc51884a9c7353d9e5bad8","from":"ACG"};</script>';
      final result = FastVideoSourceResolverPlayerVarProbe.extract(html);
      expect(result, isNull);
    });
  });

  group('§1.1(c) isLikelyMediaUrl（needsPositiveConfirm 推导）', () {
    test('视频扩展名 → 强媒体信号', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://a.com/v/x.m3u8'),
          isTrue);
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://a.com/v/x.mp4?sign=1'),
          isTrue);
    });

    test('query 含 .m3u8/.mp4 → 强信号', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://a.com/api.php?type=m3u8'),
          isTrue);
    });

    test('cdn/vod host + 路径深度≥2 → 强信号', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://vod.example.com/2024/abc/playlist'),
          isTrue);
      // 路径深度 1：弱信号
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://vod.example.com/playlist'),
          isFalse);
    });

    test('无信号的 /play?token= 形态 → 需正向确认', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://www.example.com/play?token=xyz'),
          isFalse);
    });
  });

  group('§1.1(d) 解析器二跳纯函数', () {
    test('composeParserRequest：?url= 结尾直接追加', () {
      expect(
          FastVideoSourceResolverCandidateProbe.composeParserRequest(
              'https://jx.x.com/?url=', 'ACG-token'),
          'https://jx.x.com/?url=ACG-token');
      expect(
          FastVideoSourceResolverCandidateProbe.composeParserRequest(
              'https://jx.x.com/parse=', 'tok en'),
          'https://jx.x.com/parse=tok%20en');
    });

    test('composeParserRequest：已有 query 补 &url=，否则补 ?url=', () {
      expect(
          FastVideoSourceResolverCandidateProbe.composeParserRequest(
              'https://jx.x.com/api.php?type=json', 'abc'),
          'https://jx.x.com/api.php?type=json&url=abc');
      expect(
          FastVideoSourceResolverCandidateProbe.composeParserRequest(
              'https://jx.x.com/api.php', 'abc'),
          'https://jx.x.com/api.php?url=abc');
    });

    test('extractFromParserJson：url/m3u8/link/data.url 字段族', () {
      expect(
          FastVideoSourceResolverCandidateProbe.extractFromParserJson(
              '{"url":"https://cdn.x.com/a.m3u8"}'),
          ['https://cdn.x.com/a.m3u8']);
      expect(
          FastVideoSourceResolverCandidateProbe.extractFromParserJson(
              '{"m3u8":"https://cdn.x.com/a.m3u8"}'),
          ['https://cdn.x.com/a.m3u8']);
      expect(
          FastVideoSourceResolverCandidateProbe.extractFromParserJson(
              '{"link":"https://cdn.x.com/a.m3u8"}'),
          ['https://cdn.x.com/a.m3u8']);
      expect(
          FastVideoSourceResolverCandidateProbe.extractFromParserJson(
              '{"data":{"url":"https://cdn.x.com/a.m3u8"}}'),
          ['https://cdn.x.com/a.m3u8']);
      // 非直链字段不产出
      expect(
          FastVideoSourceResolverCandidateProbe.extractFromParserJson(
              '{"url":"not-a-url"}'),
          isEmpty);
      expect(
          FastVideoSourceResolverCandidateProbe.extractFromParserJson(
              'not json'),
          isEmpty);
    });

    test('§1.1(f) 广告路径去噪', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isAdPath(
              'https://cdn.x.com/preroll/ad1.mp4'),
          isTrue);
      expect(
          FastVideoSourceResolverCandidateProbe.isAdPath(
              'https://cdn.x.com/video/loading.mp4'),
          isTrue);
      expect(
          FastVideoSourceResolverCandidateProbe.isAdPath(
              'https://cdn.x.com/video/main.m3u8'),
          isFalse);
    });
  });

  group('§1.2 探测正向确认（纯函数）', () {
    test('媒体魔数：ftyp / 0x47 TS 同步 / FLV / EBML', () {
      expect(
          HybridVideoSourceServiceProbe.sniffMediaBytes(
              [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]),
          isTrue); // ftyp @4
      expect(HybridVideoSourceServiceProbe.sniffMediaBytes([0x47, 1, 2, 3]),
          isTrue); // TS
      expect(
          HybridVideoSourceServiceProbe.sniffMediaBytes(
              [0x46, 0x4C, 0x56, 1]),
          isTrue); // FLV
      expect(HybridVideoSourceServiceProbe.sniffMediaBytes([0x1A, 0x45, 1, 2]),
          isTrue); // EBML
      expect(
          HybridVideoSourceServiceProbe.sniffMediaBytes(
              [0x3C, 0x68, 0x74, 0x6D]),
          isFalse); // '<htm'
      expect(HybridVideoSourceServiceProbe.sniffMediaBytes([1, 2]),
          isFalse); // 过短
    });
  });

  group('§1.5 WebView 网络层嗅探 URL 判定（纯函数）', () {
    test('VideoWebviewAndroidImplProbe.isSniffableMediaUrl', () {
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://cdn.x.com/v/index.m3u8'), isTrue);
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://cdn.x.com/v/seg-1.ts?token=1'), isFalse, // ts 不是嗅探目标
          reason: '分片 .ts 不该当清单上报，只有 m3u8/mp4 等容器级 URL 才上报');
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://cdn.x.com/v/index.m3u8?token=1'), isTrue);
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://x.com/api.php?url=xx.m3u8'), isTrue, reason: 'query 含 .m3u8');
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://x.com/playlist.m3u8'), isTrue);
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://x.com/page.html'), isFalse);
      expect(VideoWebviewAndroidImplProbe.isSniffableMediaUrl(
          'https://x.com/app.js'), isFalse);
    });
  });

  group('§1.3 负缓存分级 TTL', () {
    // 用超短 TTL 驱动过期，避免真实等待分钟级时间。
    test('putNegative 自定义 TTL：未过期命中、过期自动清除', () async {
      final cache = ResolutionResultCache.instance;
      const key = 'https://neg.example.com/play/1.html#negtest';
      await cache.putNegative(key,
          ttl: const Duration(milliseconds: 300));
      expect(await cache.isNegative(key), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await cache.isNegative(key), isFalse,
          reason: 'TTL 过期的负缓存应被清除');
      await cache.invalidate(key);
    });

    test('probeDead（5min）与 extractFailed（10min）常量分级', () {
      expect(ResolutionResultCache.probeDeadTtl.inMinutes, 5);
      expect(ResolutionResultCache.extractFailedTtl.inMinutes, 10);
      expect(ResolutionResultCache.negativeTtl.inSeconds, 60);
    });

    test('网络抖动（network kind）不写持久负缓存——由 hybrid 保证，'
        '此处锁定 putNegative 的负条目不会覆盖正条目语义', () async {
      final cache = ResolutionResultCache.instance;
      const key = 'https://pos.example.com/play/1.html#postest';
      await cache.put(
        key,
        VideoSource(
            url: 'https://cdn.example.com/v.m3u8',
            offset: 0,
            type: VideoSourceType.online,
            format: VideoSourceFormat.hls),
      );
      // 已有正条目时 putNegative 直接返回（不覆盖），get 不受影响
      await cache.putNegative(key);
      final source = await cache.get(key);
      expect(source, isNotNull);
      await cache.invalidate(key);
    });
  });

  group('§1.4 云端端点健康持久化 + 熔断跳过', () {
    late HttpServer badEndpoint;
    late HttpServer goodEndpoint;
    var badHealthRequests = 0;

    setUp(() async {
      badHealthRequests = 0;
      CloudVideoSourceResolver.instance.invalidateEndpoints();

      badEndpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      badEndpoint.listen((request) {
        if (request.uri.path == '/health') {
          badHealthRequests++;
          request.response.statusCode = 500; // 服务器故障 → 计熔断
        } else {
          request.response.statusCode = 200;
        }
        request.response.close();
      });

      goodEndpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      goodEndpoint.listen((request) {
        request.response.statusCode = 200;
        request.response.write('{"ok":true}');
        request.response.close();
      });

      await GStorage.putSetting<bool>(SettingsKeys.cloudResolverEnable, true);
      await GStorage.putSetting<String>(
        SettingsKeys.cloudResolverUrl,
        'http://127.0.0.1:${badEndpoint.port}, http://127.0.0.1:${goodEndpoint.port}',
      );
    });

    tearDown(() async {
      await badEndpoint.close(force: true);
      await goodEndpoint.close(force: true);
    });

    test('warmUp 失败计熔断 + Hive 持久化 + 第 4 次不再请求坏端点',
        () async {
      final resolver = CloudVideoSourceResolver.instance;
      // 3 轮 warmUp：坏端点连续 3 次失败 → 熔断打开
      for (var i = 0; i < 3; i++) {
        await resolver.warmUp();
      }
      expect(badHealthRequests, 3,
          reason: '熔断阈值 3：坏端点恰好被请求 3 次');

      // 持久化验证：Hive 盒里坏端点的失败计数 = 3
      final box = await Hive.openBox('cloud_resolver_health');
      final health = box.get('health');
      expect(health, isA<Map>());
      final badKey = 'http://127.0.0.1:${badEndpoint.port}/resolve';
      expect((health as Map)[badKey], isNotNull,
          reason: '坏端点健康状态应持久化到 Hive');
      final entry = health[badKey] as Map;
      expect(entry['f'], 3);

      // 第 4 轮：坏端点已被熔断，不再收到请求
      await resolver.warmUp();
      expect(badHealthRequests, 3,
          reason: '熔断打开后 warmUp 不应再请求坏端点');

      // 清理：测试间不串扰
      await box.put('health', <String, dynamic>{});
    });
  });
}
