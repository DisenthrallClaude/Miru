// ResolutionResultCache 语义回归锁。
//
// v1.6.9（P1-5）：put 的 overwrite 参数——预取路径写入的是未探测的
// 首候选，不得覆盖未过期的正条目（缓存里可能是刚验证过可用性的
// 播放结果）；正式解析路径保持默认覆盖语义（force 重解析依赖）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/resolution_result_cache.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';

VideoSource _source(String url) => VideoSource(
      url: url,
      offset: 0,
      type: VideoSourceType.online,
      format: VideoSourceFormat.auto,
    );

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
        return '/tmp/miru_resolution_cache_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_resolution_cache_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_resolution_cache_test/hive');
    await GStorage.init();
  });

  setUp(() async {
    await ResolutionResultCache.instance.clear();
  });

  test('P1-5: overwrite=false 不得覆盖未过期正条目（预取路径语义）',
      () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/1.html#e1';
    // 正式解析写入（已验证的播放结果）。
    await cache.put(url, _source('https://cdn.example.com/verified.m3u8'));
    // 后台预取拿到另一个未探测候选，试图覆盖。
    await cache.put(url, _source('https://cdn.example.com/unverified.m3u8'),
        overwrite: false);
    final hit = await cache.get(url);
    expect(hit?.url, 'https://cdn.example.com/verified.m3u8',
        reason: '预取不得把已验证正条目顶成未探测候选（P1-5 病灶）');
  });

  test('P1-5: overwrite=true（默认）保持覆盖语义（force 重解析依赖）',
      () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/2.html#e2';
    await cache.put(url, _source('https://cdn.example.com/old.m3u8'));
    await cache.put(url, _source('https://cdn.example.com/new.m3u8'));
    final hit = await cache.get(url);
    expect(hit?.url, 'https://cdn.example.com/new.m3u8',
        reason: '正式解析必须能覆盖旧条目（失效重写/force 重解析）');
  });

  test('P1-5: overwrite=false 可以覆盖负条目与过期正条目', () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/3.html#e3';
    // 负条目：预取成功后应能写入（否则负缓存把预取结果全堵死）。
    await cache.putNegative(url);
    await cache.put(url, _source('https://cdn.example.com/fresh.m3u8'),
        overwrite: false);
    final hit = await cache.get(url);
    expect(hit?.url, 'https://cdn.example.com/fresh.m3u8',
        reason: '负条目必须允许被预取结果覆盖');
  });

  // -------------------------------------------------------------------------
  // v1.7.0（P0-4/P0-6/P2-6/P2-7）
  // -------------------------------------------------------------------------

  test('P0-4: verified 标记——预取写入 false，首帧回写后 true', () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/4.html#e4';
    await cache.put(url, _source('https://cdn.example.com/a.m3u8'),
        verified: false);
    expect(await cache.isVerified(url), isFalse,
        reason: '未验证条目不能免探测直用');
    // 首帧确认 → 回写。
    await cache.markVerified(url);
    expect(await cache.isVerified(url), isTrue);
    // 幂等：重复回写无害。
    await cache.markVerified(url);
    expect(await cache.isVerified(url), isTrue);
  });

  test('P0-4: 默认写入为 verified（正式解析路径语义）', () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/5.html#e5';
    await cache.put(url, _source('https://cdn.example.com/b.m3u8'));
    expect(await cache.isVerified(url), isTrue);
  });

  test('P0-6: cookie 不持久化，referer/origin 保留', () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/6.html#e6';
    await cache.put(
      url,
      VideoSource(
        url: 'https://cdn.example.com/c.m3u8',
        offset: 0,
        type: VideoSourceType.online,
        format: VideoSourceFormat.auto,
        playbackHeaders: {
          'referer': 'https://cdn.example.com/',
          'origin': 'https://cdn.example.com',
          'cookie': 'cf_clearance=stale_secret; x=1',
          'user-agent': 'UA',
        },
      ),
    );
    await cache.flush();
    final file = File(
        '/tmp/miru_resolution_cache_test/resolution_cache.json');
    final raw = await file.readAsString();
    expect(raw.contains('cookie'), isFalse,
        reason: '缓存文件不得出现 cookie（明文隐私 + 过期覆盖根因）');
    expect(raw.contains('cf_clearance'), isFalse);
    expect(raw.contains('stale_secret'), isFalse);
    // referer/origin 正常持久化。
    expect(raw.contains('cdn.example.com'), isTrue);
    // 内存条目的头同样只剩 referer/origin。
    final hit = await cache.get(url);
    expect(hit?.playbackHeaders.containsKey('cookie'), isFalse);
    expect(hit?.playbackHeaders['referer'], 'https://cdn.example.com/');
    expect(hit?.playbackHeaders['origin'], 'https://cdn.example.com');
  });

  test('P0-6: 旧缓存文件里的 cookie 在加载时被丢弃', () async {
    final dir = Directory('/tmp/miru_resolution_cache_test');
    // 手工构造带 cookie 的旧格式文件。
    final now = DateTime.now().millisecondsSinceEpoch;
    final legacy = {
      'https://example.com/legacy.html': {
        'v': 'https://cdn.example.com/legacy.m3u8',
        'o': 0,
        'f': 'auto',
        'n': 0,
        'p': {
          'referer': 'https://cdn.example.com/',
          'cookie': 'cf_clearance=legacy_secret',
        },
        'c': now,
        'u': now,
      },
    };
    await File('${dir.path}/resolution_cache.json')
        .writeAsString(json.encode(legacy));
    // 重置记忆化加载，强制从磁盘重读旧格式文件。
    await ResolutionResultCache.instance.debugResetForTest();
    final hit = await ResolutionResultCache.instance
        .get('https://example.com/legacy.html');
    expect(hit, isNotNull);
    expect(hit!.playbackHeaders.containsKey('cookie'), isFalse,
        reason: '旧文件里的 cookie 必须在加载时丢弃');
    expect(hit.playbackHeaders['referer'], 'https://cdn.example.com/');
  });

  test('P2-6: 坏 JSON 文件被隔离为 .corrupt，缓存从头开始', () async {
    final dir = Directory('/tmp/miru_resolution_cache_test');
    final file = File('${dir.path}/resolution_cache.json');
    await file.writeAsString('{"broken": [1, 2');
    // 重置记忆化加载，强制重读坏文件。
    await ResolutionResultCache.instance.debugResetForTest();
    final hit = await ResolutionResultCache.instance.get('https://x.com/a');
    expect(hit, isNull);
    expect(await File('${dir.path}/resolution_cache.json.corrupt').exists(),
        isTrue,
        reason: '坏文件必须被改名隔离，否则每次启动重复读坏文件');
    // 隔离后后续写入正常（新文件路径重建）。
    await ResolutionResultCache.instance
        .put('https://x.com/a', _source('https://cdn.x.com/a.m3u8'));
    final after = await ResolutionResultCache.instance.get('https://x.com/a');
    expect(after?.url, 'https://cdn.x.com/a.m3u8');
  });

  test('P2-7: putNegative 可覆盖已过期条目', () async {
    final cache = ResolutionResultCache.instance;
    const url = 'https://example.com/play/7.html#e7';
    // 写入一个 1 秒 TTL 的条目并等它过期。
    await cache.put(url, _source('https://cdn.example.com/d.m3u8'),
        ttl: const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    // 过期后负缓存应能写入（旧实现连过期条目也拒绝）。
    await cache.putNegative(url);
    expect(await cache.isNegative(url), isTrue);
    expect(await cache.get(url), isNull);
  });
}
