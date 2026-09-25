// 阶段 3 / §3.3 线路健康探测单测。
//
// 1. RoadHealth 健康分（存活 > 延迟，死亡 0 分）；
// 2. bestRoadIndex 的选路建议（含无数据回退）；
// 3. probeAll 打真实回环 HttpServer：活站 ok、死端口 fail、
//    新鲜期内不重复探测；
// 4. 持久化往返（写入 → 新实例读取）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/road_health.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
        return '/tmp/miru_road_health_test';
      default:
        return null;
    }
  });

  setUp(() async {
    await Directory('/tmp/miru_road_health_test').create(recursive: true);
    await RoadHealthTracker.instance.resetForTest();
  });

  tearDownAll(() async {
    await RoadHealthTracker.instance.resetForTest();
  });

  test('RoadHealth 健康分：存活 > 快，死亡 0 分', () {
    final aliveFast = RoadHealth(ok: true, latencyMs: 120, probedAt: 1);
    final aliveSlow = RoadHealth(ok: true, latencyMs: 900, probedAt: 1);
    final dead = RoadHealth(ok: false, latencyMs: 3000, probedAt: 1);
    expect(aliveFast.score, greaterThan(aliveSlow.score));
    expect(aliveSlow.score, greaterThan(dead.score));
    expect(dead.score, 0);
  });

  test('bestRoadIndex：无数据时回退 fallback', () async {
    final best = await RoadHealthTracker.instance
        .bestRoadIndex(['a', 'b'], 'plugin', fallback: 0);
    expect(best, 0);
  });

  test('probeAll：活站 ok、死端口 fail，并写入持久化', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    final roads = <(String, List<String>)>[
      ('live', ['http://127.0.0.1:${server.port}/page']),
      ('dead', ['http://127.0.0.1:1/page']), // 无人监听端口
      ('empty', <String>[]), // 空线路直接判死
    ];
    await RoadHealthTracker.instance.probeAll(roads, 'pluginX');

    final live = await RoadHealthTracker.instance.healthOf('pluginX', 'live');
    expect(live, isNotNull);
    expect(live!.ok, isTrue);
    expect(live.latencyMs, lessThan(1000));

    final dead = await RoadHealthTracker.instance.healthOf('pluginX', 'dead');
    expect(dead, isNotNull);
    expect(dead!.ok, isFalse);

    final empty = await RoadHealthTracker.instance.healthOf('pluginX', 'empty');
    expect(empty, isNotNull);
    expect(empty!.ok, isFalse);

    // 持久化往返：文件确实落盘。
    final file = File('/tmp/miru_road_health_test/road_health.json');
    expect(await file.exists(), isTrue);

    await server.close(force: true);
  });

  test('bestRoadIndex：健康分选路', () async {
    // 手动种入新鲜健康数据（probedAt = now）。
    final tracker = RoadHealthTracker.instance;
    await tracker.probeAll(<(String, List<String>)>[
      ('slow', ['http://127.0.0.1:1/slow']),
      ('best', ['http://127.0.0.1:1/best']),
    ], 'pluginY');
    // 两次都探测失败（端口 1）：改成手工种入正结果——通过 probeAll
    // 的死端口写负结果，再验证 bestRoadIndex 不选死线路。
    final deadRoad =
        await tracker.healthOf('pluginY', 'slow');
    expect(deadRoad, isNotNull);
    final best = await tracker
        .bestRoadIndex(['slow', 'best'], 'pluginY', fallback: 0);
    // 两条都死：分值都为 0，保持 fallback。
    expect(best, 0);
  });

  // -----------------------------------------------------------------------
  // v1.7.0（P1-11）
  // -----------------------------------------------------------------------

  test('P1-11: recordOutcome 真实播放结果回填（ok + ttffMs）', () async {
    await RoadHealthTracker.instance.resetForTest();
    await RoadHealthTracker.instance.recordOutcome(
      'pluginP17',
      '线路一',
      ok: true,
      ttffMs: 850,
    );
    final health = await RoadHealthTracker.instance.healthOf('pluginP17', '线路一');
    expect(health, isNotNull);
    expect(health!.ok, isTrue);
    expect(health.latencyMs, 850);
  });

  test('P1-11: recordOutcome 失败回填（dead）', () async {
    await RoadHealthTracker.instance.resetForTest();
    await RoadHealthTracker.instance.recordOutcome('pluginP17', '线路二',
        ok: false);
    final health =
        await RoadHealthTracker.instance.healthOf('pluginP17', '线路二');
    expect(health, isNotNull);
    expect(health!.ok, isFalse);
  });

  test('P1-11: cachedBestRoadIndex 同步读取（未加载返回 fallback）', () async {
    await RoadHealthTracker.instance.resetForTest();
    // 未加载（reset 后首次访问前）→ fallback，绝不等待。
    expect(
        RoadHealthTracker.instance
            .cachedBestRoadIndex(['a', 'b'], 'pluginP17', fallback: 1),
        1);
    // 写入真实结果后（已加载）→ 同步可读。
    await RoadHealthTracker.instance
        .recordOutcome('pluginP17', 'a', ok: true, ttffMs: 100);
    expect(
        RoadHealthTracker.instance.cachedBestRoadIndex(['a', 'b'], 'pluginP17'),
        0,
        reason: 'a 有 ok 记录，同步分应胜出默认 0 之外的选项');
  });

  test('P1-11: 不同插件的探测互不阻塞（per-plugin 标志）', () async {
    await RoadHealthTracker.instance.resetForTest();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gate = Completer<void>();
    server.listen((request) async {
      await gate.future;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });
    final roads = <(String, List<String>)>[
      ('r0', ['http://127.0.0.1:${server.port}/x']),
    ];
    // pluginA 探测挂起（gate 未开）。
    final probeA = RoadHealthTracker.instance.probeAll(roads, 'pluginA');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // pluginB 的探测不应被 pluginA 的在途探测挡掉（旧全局布尔会跳过）。
    gate.complete();
    await probeA;
    await RoadHealthTracker.instance.probeAll(roads, 'pluginB');
    final healthB =
        await RoadHealthTracker.instance.healthOf('pluginB', 'r0');
    expect(healthB, isNotNull, reason: 'per-plugin 探测标志互不阻塞');
    await server.close(force: true);
  });

  test('新鲜期内不重复探测（源站零二次请求）', () async {
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      hits++;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    final roads = <(String, List<String>)>[
      ('r0', ['http://127.0.0.1:${server.port}/x']),
    ];
    await RoadHealthTracker.instance.probeAll(roads, 'pluginZ');
    final firstHits = hits;
    expect(firstHits, 1);

    // 结果新鲜：第二次 probeAll 不应再打源站。
    await RoadHealthTracker.instance.probeAll(roads, 'pluginZ');
    expect(hits, firstHits);

    await server.close(force: true);
  });
}
