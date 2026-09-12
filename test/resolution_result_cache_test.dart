// ResolutionResultCache 语义回归锁。
//
// v1.6.9（P1-5）：put 的 overwrite 参数——预取路径写入的是未探测的
// 首候选，不得覆盖未过期的正条目（缓存里可能是刚验证过可用性的
// 播放结果）；正式解析路径保持默认覆盖语义（force 重解析依赖）。
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
}
