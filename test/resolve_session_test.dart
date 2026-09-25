// 阶段 2 / §2.2 对冲竞速调度器单测。
//
// 用假层级任务（可控延迟/结果/异常）验证波次语义：
// 1. t=0 层最快产出 → 后续波次不启动；
// 2. 首层 yield → 600ms 层接手产出；
// 3. 全部 yield → 立即以 TimeoutException 失败（v1.6.9：不再等硬上限）；
// 4. 外部 cancel → 立即以异常收场；
// 5. 层级抛异常不终止竞速（后续波次仍可胜出）。
// 6. run() 重入幂等（v1.6.9 P0-5：复用同一 future，不再抛 StateError）。
// 7. ttlFor 的 exp 提取与 clamp。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/resolve_session.dart';

void main() {
  test('t=0 层先产出：胜出且后续波次不启动', () async {
    var laterLaunched = false;
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 'fast';
        },
        const Duration(milliseconds: 100): (trace) async {
          laterLaunched = true;
          return 'cloud';
        },
      },
      hardDeadline: const Duration(seconds: 2),
    );
    final result = await session.run();
    expect(result, 'fast');
    // 胜出后 100ms 波次不再启动。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(laterLaunched, isFalse);
  });

  test('首层 yield：600ms 层接手产出', () async {
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async => null, // fast 放弃
        const Duration(milliseconds: 60): (trace) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'cloud';
        },
        const Duration(milliseconds: 300): (trace) async {
          fail('webview 波次不应启动：cloud 已胜出');
        },
      },
      hardDeadline: const Duration(seconds: 2),
    );
    final result = await session.run();
    expect(result, 'cloud');
  });

  test('全部 yield：立即失败（不再等硬上限）', () async {
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async => null,
        const Duration(milliseconds: 50): (trace) async => null,
      },
      hardDeadline: const Duration(seconds: 10),
    );
    final sw = Stopwatch()..start();
    await expectLater(
      session.run(),
      throwsA(isA<TimeoutException>()),
    );
    sw.stop();
    // v1.6.9：全部波次落定即失败——若仍在等 10s 硬上限，这里会超秒。
    expect(sw.elapsed.inSeconds, lessThan(5));
  });

  test('层级抛异常不终止竞速：后续波次仍可胜出', () async {
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async => throw StateError('fast crashed'),
        const Duration(milliseconds: 60): (trace) async => 'webview',
      },
      hardDeadline: const Duration(seconds: 2),
    );
    final result = await session.run();
    expect(result, 'webview');
  });

  test('外部 cancel：会话立即以异常收场', () async {
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) => Completer<String>().future, // 永不产出
      },
      hardDeadline: const Duration(seconds: 10),
    );
    final future = session.run();
    // 让 _launch 有机会启动任务。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    session.cancel();
    await expectLater(
      future,
      throwsA(isA<TimeoutException>()),
    );
  });

  test('run() 重入幂等（v1.6.9 P0-5）：复用同一 future', () async {
    final session = ResolveSession<int>(
      waves: {Duration.zero: (trace) async => 1},
      hardDeadline: const Duration(seconds: 1),
    );
    final first = await session.run();
    // 旧实现这里抛 StateError，上层重试/双击会把整次解析打断。
    final second = await session.run();
    expect(second, first);
  });

  test('ResolveTrace：环形淘汰与导出', () {
    final trace = ResolveTrace(capacity: 3);
    trace.record(ResolveStage.fast, 'e1');
    trace.record(ResolveStage.fast, 'e2', 'detail');
    trace.record(ResolveStage.cloud, 'e3');
    trace.record(ResolveStage.webview, 'e4'); // 挤掉 e1
    final exported = trace.export();
    expect(exported, contains('e2'));
    expect(exported, contains('detail'));
    expect(exported, contains('e4'));
    expect(exported.contains('e1'), isFalse);
  });

  // -------------------------------------------------------------------------
  // v1.7.0（P1-3）
  // -------------------------------------------------------------------------

  test('P1-3: 失败即晋级——wave0 在 50ms 返回 null，wave1 立即启动（不等 600ms）',
      () async {
    final wave1LaunchAt = Completer<DateTime>();
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return null; // 快解 50ms 就失败
        },
        const Duration(milliseconds: 600): (trace) async {
          if (!wave1LaunchAt.isCompleted) {
            wave1LaunchAt.complete(DateTime.now());
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'cloud';
        },
        const Duration(milliseconds: 1500): (trace) async {
          fail('webview 波次不应启动：cloud 已胜出');
        },
      },
      hardDeadline: const Duration(seconds: 2),
    );
    final startAt = DateTime.now();
    final result = await session.run();
    expect(result, 'cloud');
    // 验收（工单原文）：wave1 在大约 50ms 时启动，而不是 600ms。
    final launchDelay =
        wave1LaunchAt.future.then((at) => at.difference(startAt).inMilliseconds);
    final ms = await launchDelay;
    expect(ms, lessThan(400),
        reason: '失败即晋级：wave0 落定后 wave1 应立即启动，'
            '实测 ${ms}ms（旧实现要等满 600ms）');
  });

  test('P1-3: 层级抛异常同样触发晋级', () async {
    var webviewLaunched = false;
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async => throw Exception('fast crashed'),
        const Duration(milliseconds: 600): (trace) async => null,
        const Duration(milliseconds: 1500): (trace) async {
          webviewLaunched = true;
          return 'webview';
        },
      },
      hardDeadline: const Duration(seconds: 2),
    );
    final result = await session.run();
    expect(result, 'webview');
    expect(webviewLaunched, isTrue);
  });

  test('P1-3: 胜出后待触发的波次定时器全部取消（无迟到启动）', () async {
    var lateLaunched = false;
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async => 'fast',
        const Duration(milliseconds: 80): (trace) async {
          lateLaunched = true;
          return 'cloud';
        },
      },
      hardDeadline: const Duration(seconds: 2),
    );
    expect(await session.run(), 'fast');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(lateLaunched, isFalse,
        reason: '胜出后未触发的波次定时器必须取消');
  });

  group('ttlFor：URL 签名寿命提取（§2.4）', () {
    test('秒级 exp', () {
      final future = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 1800;
      final ttl = ttlFor('https://cdn.example.com/v.mp4?exp=$future');
      expect(ttl, isNotNull);
      expect(ttl!.inMinutes, inInclusiveRange(28, 31));
    });

    test('毫秒级 exp 自动识别', () {
      final futureMs = DateTime.now().millisecondsSinceEpoch + 1800000;
      final ttl = ttlFor('https://cdn.example.com/v.mp4?expires=$futureMs');
      expect(ttl, isNotNull);
      expect(ttl!.inMinutes, inInclusiveRange(28, 31));
    });

    test('过期签名 clamp 到 1min 下限', () {
      final past = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 500;
      expect(ttlFor('https://cdn.example.com/v.mp4?exp=$past')!.inMinutes, 1);
    });

    test('超长寿命 clamp 到 6h 上限', () {
      final far = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 86400;
      expect(ttlFor('https://cdn.example.com/v.mp4?exp=$far')!.inHours, 6);
    });

    test('无签名参数返回 null', () {
      expect(ttlFor('https://cdn.example.com/v.mp4'), isNull);
      expect(ttlFor('https://cdn.example.com/v.mp4?token=abc'), isNull);
    });

    test('非数字 exp 返回 null', () {
      expect(ttlFor('https://cdn.example.com/v.mp4?exp=abc'), isNull);
    });

    // v1.7.0（P2-5）
    test('P2-5: t 键不再参与判定（大量站点的 t 是生成时间，恒判过期）',
        () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // 只有 t（生成时间，过去值）：不得返回 1min（旧行为），应返回 null
      //（无有效过期签名 → 默认 30min TTL）。
      expect(ttlFor('https://cdn.example.com/v.mp4?t=$now'), isNull);
      expect(
          ttlFor('https://cdn.example.com/v.mp4?t=${now - 500}'), isNull);
    });

    test('P2-5: e 键负剩余视同生成时间跳过，正剩余正常采用', () {
      final past = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 500;
      final future = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 1800;
      // e 在过去：跳过 → 无其他键 → null。
      expect(ttlFor('https://cdn.example.com/v.mp4?e=$past'), isNull);
      // e 在未来：正常作为过期时刻。
      final ttl = ttlFor('https://cdn.example.com/v.mp4?e=$future');
      expect(ttl, isNotNull);
      expect(ttl!.inMinutes, inInclusiveRange(28, 31));
    });
  });
}
