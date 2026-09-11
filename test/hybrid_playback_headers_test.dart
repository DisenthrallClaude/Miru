// v1.6.8（R-1）回归锁：hybrid 层 _materialize 的播放头合并方向。
//
// 病灶（reviews/v168-agent-P2.md R-1）：`{...source.playbackHeaders,
// ...headers}`（插件头在后展开获胜）——嗅探捕获的 CDN 真实 referer/
// cookie 在 hybrid 层就被插件硬编码头覆盖，永远到不了 mpv；而三处探测
// （缓存命中/fast 候选/云端结果）都是解析层头优先，于是「探测通过 →
// 播放 403 → 直连兜底同头再 403 → 自动恢复烧完 → 黑屏 + 换线路循环」。
// v1.6.7 曾在 video_controller:833 翻转过一次，但塌陷点在 hybrid 层，
// 那次翻转是 no-op。
//
// 测试走真实入口 resolveWithHeaders 的缓存命中路径（prefetchEnabled:
// false 跳过代理/预取，纯头合并逻辑，无网络）：
// 1. 插件头与嗅探头冲突 → 嗅探 referer/cookie 必须获胜；
// 2. 嗅探未覆盖的键 → 插件头补位（基底语义不被破坏）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/hybrid_video_source_service.dart';
import 'package:miru/services/video_source/resolution_result_cache.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';

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
        return '/tmp/miru_hybrid_headers_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_hybrid_headers_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_hybrid_headers_test/hive');
    await GStorage.init();
  });

  test('R-1: 插件 referer/cookie 与嗅探值冲突时，嗅探值必须获胜', () async {
    final cache = ResolutionResultCache.instance;
    // 模拟 webview 波胜出后写入缓存的嗅探结果：
    // playbackHeaders = 嗅探捕获的 CDN 侧真实 referer/cookie。
    const episodeUrl = 'https://www.example.com/play/1.html#r1-conflict';
    const sniffed = VideoSource(
      url: 'https://cdn.example.com/v/1/index.m3u8',
      offset: 0,
      type: VideoSourceType.online,
      format: VideoSourceFormat.hls,
      playbackHeaders: {
        'referer': 'https://cdn.example.com/',
        'cookie': 'cdn_sess=sniffed',
      },
    );
    await cache.put(episodeUrl, sniffed);
    try {
      final result = await HybridVideoSourceService().resolveWithHeaders(
        episodeUrl,
        useLegacyParser: false,
        prefetchEnabled: false,
        // 插件声明的头（KazumiRules 导入规则极普遍：硬编码 referer，
        // 常是站点首页——对 CDN 域名鉴权型源这就是 403 头）。
        playbackHeaders: {
          'referer': 'https://www.example.com/',
          'cookie': 'page_cookie=plugin',
        },
      );
      expect(result.playbackHeaders['referer'], 'https://cdn.example.com/',
          reason: '嗅探 referer 被插件 referer 覆盖（R-1 病灶回归）');
      expect(result.playbackHeaders['cookie'], 'cdn_sess=sniffed',
          reason: '嗅探 cookie 被插件 cookie 覆盖（R-1 病灶回归）');
    } finally {
      await cache.invalidate(episodeUrl);
    }
  });

  test('R-1: 嗅探未覆盖的键由插件头补位（基底语义不破坏）', () async {
    final cache = ResolutionResultCache.instance;
    // 嗅探只带回了 referer（无 cookie/UA）——fast/cloud 层结果常态。
    const episodeUrl = 'https://www.example.com/play/2.html#r1-complement';
    const sniffed = VideoSource(
      url: 'https://cdn.example.com/v/2/index.m3u8',
      offset: 0,
      type: VideoSourceType.online,
      format: VideoSourceFormat.hls,
      playbackHeaders: {
        'referer': 'https://cdn.example.com/',
      },
    );
    await cache.put(episodeUrl, sniffed);
    try {
      final result = await HybridVideoSourceService().resolveWithHeaders(
        episodeUrl,
        useLegacyParser: false,
        prefetchEnabled: false,
        // 插件只声明了 cookie（无 referer）：嗅探 referer 保留，
        // cookie 由插件补位，UA 由会话 UA 兜底。
        playbackHeaders: {
          'cookie': 'page_cookie=plugin',
        },
      );
      expect(result.playbackHeaders['referer'], 'https://cdn.example.com/',
          reason: '嗅探 referer 必须保留');
      expect(result.playbackHeaders['cookie'], 'page_cookie=plugin',
          reason: '嗅探未覆盖 cookie 时插件 cookie 应补位（基底语义）');
      expect(
        (result.playbackHeaders['user-agent'] ?? '').isNotEmpty,
        isTrue,
        reason: 'UA 应由会话 UA 兜底（插件基底）',
      );
    } finally {
      await cache.invalidate(episodeUrl);
    }
  });
}
