// 阶段 2 / §2.2 对冲竞速调度器单测。
//
// 用假层级任务（可控延迟/结果/异常）验证波次语义：
// 1. t=0 层最快产出 → 后续波次不启动；
// 2. 首层 yield → 600ms 层接手产出；
// 3. 全部 yield → 硬上限抛 TimeoutException；
// 4. 外部 cancel → 立即以异常收场；
// 5. 层级抛异常不终止竞速（后续波次仍可胜出）。
// 6. ttlFor 的 exp 提取与 clamp。
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

  test('全部 yield：硬上限抛 TimeoutException', () async {
    final session = ResolveSession<String>(
      waves: {
        Duration.zero: (trace) async => null,
        const Duration(milliseconds: 50): (trace) async => null,
      },
      hardDeadline: const Duration(milliseconds: 300),
    );
    await expectLater(
      session.run(),
      throwsA(isA<TimeoutException>()),
    );
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

  test('run() 只能调用一次', () async {
    final session = ResolveSession<int>(
      waves: {Duration.zero: (trace) async => 1},
      hardDeadline: const Duration(seconds: 1),
    );
    await session.run();
    expect(() => session.run(), throwsStateError);
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
  });
}
