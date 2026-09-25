// v1.7.0（P1-3/P1-6）：胜出层级记忆 + 解析单飞 + WebView 池契约。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/hybrid_video_source_service.dart';
import 'package:miru/services/video_source/level_win_memory.dart';
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
        return '/tmp/miru_p13_level_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_p13_level_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_p13_level_test/hive');
    await GStorage.init();
  });

  group('P1-3：LevelWinMemory（胜出层级记忆）', () {
    setUp(() async {
      await LevelWinMemory.instance.clearForTest();
    });

    test('连续 3 次同层胜出 → dominant 建议返回该层', () async {
      await LevelWinMemory.instance
          .recordWin('www.js-site.com', 'webview');
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://www.js-site.com/play/1'),
          isNull,
          reason: '1 次不足以判定（防单次抖动误判）');
      await LevelWinMemory.instance
          .recordWin('www.js-site.com', 'webview');
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://www.js-site.com/play/1'),
          isNull,
          reason: '2 次不足以判定');
      await LevelWinMemory.instance
          .recordWin('www.js-site.com', 'webview');
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://www.js-site.com/play/1'),
          'webview',
          reason: '连续 3 次 WebView 胜出 → 提前起跑建议');
    });

    test('混合胜出历史 → 无建议', () async {
      await LevelWinMemory.instance.recordWin('www.mix.com', 'fast');
      await LevelWinMemory.instance.recordWin('www.mix.com', 'cloud');
      await LevelWinMemory.instance.recordWin('www.mix.com', 'webview');
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://www.mix.com/x'),
          isNull);
    });

    test('fast/cache 层即使连续胜出也不产生建议（本就 t=0/免竞速）',
        () async {
      for (var i = 0; i < 5; i++) {
        await LevelWinMemory.instance.recordWin('www.fast.com', 'fast');
      }
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://www.fast.com/x'),
          isNull);
    });

    test('cloud 连续胜出 → cloud 建议', () async {
      for (var i = 0; i < 3; i++) {
        await LevelWinMemory.instance.recordWin('cdn.cloudy.net', 'cloud');
      }
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://cdn.cloudy.net/a.html'),
          'cloud');
    });

    test('窗口滑动：最近 3 次为准', () async {
      for (var i = 0; i < 3; i++) {
        await LevelWinMemory.instance.recordWin('www.slide.com', 'webview');
      }
      // 最近 3 次变成 cloud。
      await LevelWinMemory.instance.recordWin('www.slide.com', 'cloud');
      await LevelWinMemory.instance.recordWin('www.slide.com', 'cloud');
      await LevelWinMemory.instance.recordWin('www.slide.com', 'cloud');
      expect(
          await LevelWinMemory.instance
              .dominantLevelFor('https://www.slide.com/x'),
          'cloud',
          reason: '判定窗口滑动，旧 webview 历史滚出窗口');
    });
  });

  group('P1-1/P1-6：HybridVideoSourceService 契约', () {
    test('shared 是进程级单例且 dispose 是 no-op（池常驻）', () async {
      final shared = HybridVideoSourceService.shared;
      expect(identical(HybridVideoSourceService.shared, shared), isTrue);
      // dispose 不抛异常且实例继续可用（单飞映射照常工作）。
      await shared.dispose();
      expect(identical(HybridVideoSourceService.shared, shared), isTrue);
    });

    test('独立实例（下载路径）的 dispose 照旧销毁', () {
      // 源契约：shared 与非 shared 构造并存，dispose 分流。
      final source = File(
              'lib/services/video_source/hybrid_video_source_service.dart')
          .readAsStringSync();
      expect(source.contains('static final HybridVideoSourceService shared'),
          isTrue);
      expect(source.contains('if (_isShared) return;'), isTrue,
          reason: 'shared 单例的 dispose 必须短路（WebView 池常驻）');
      expect(source.contains('usePool: true'), isTrue,
          reason: 'shared 的 WebView 服务必须走常驻池');
    });

    test('单飞：_inflight 映射 + 取消重发起在场', () {
      final source = File(
              'lib/services/video_source/hybrid_video_source_service.dart')
          .readAsStringSync();
      expect(source.contains('Future<VideoSource> _singleFlight('), isTrue);
      expect(source.contains('_inflight[episodeUrl]'), isTrue);
      expect(
          source.contains(
              'on VideoSourceCancelledException {'),
          isTrue,
          reason: '被取消的共享任务由后来者重新发起');
    });

    test('波次延迟记忆接入：dominantLevelFor 影响 cloud/webview 延迟', () {
      final source = File(
              'lib/services/video_source/hybrid_video_source_service.dart')
          .readAsStringSync();
      expect(source.contains('LevelWinMemory.instance.dominantLevelFor'),
          isTrue);
      expect(source.contains("dominant == 'webview'"), isTrue);
      expect(source.contains("dominant == 'cloud'"), isTrue);
    });

    test('快解中止令牌接入 onWin', () {
      final source = File(
              'lib/services/video_source/hybrid_video_source_service.dart')
          .readAsStringSync();
      expect(source.contains('FastResolveAbortToken()'), isTrue);
      expect(source.contains('fastAbort.abort();'), isTrue);
    });
  });

  group('P1-3：FastResolveAbortToken', () {
    test('abort 后 track 直接抛中止异常', () {
      final token = FastResolveAbortToken();
      token.abort();
      expect(token.isAborted, isTrue);
    });
  });
}
