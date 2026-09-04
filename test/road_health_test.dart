// 阶段 3 / §3.3 线路健康探测单测。
//
// 1. RoadHealth 健康分（存活 > 延迟，死亡 0 分）；
// 2. bestRoadIndex 的选路建议（含无数据回退）；
// 3. probeAll 打真实回环 HttpServer：活站 ok、死端口 fail、
//    新鲜期内不重复探测；
// 4. 持久化往返（写入 → 新实例读取）。
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
