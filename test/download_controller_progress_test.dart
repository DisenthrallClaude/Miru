import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/modules/download/download_module.dart';
import 'package:miru/pages/download/download_controller.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/repositories/download_repository.dart';
import 'package:miru/services/download/download_manager.dart';

/// v1.6.8（W-🟡1）回归锁：
/// `_onDownloadProgress` / `_failEpisode` 对仓库 `updateEpisode` 的
/// 调用必须用 `.catchError` 链接住异步 rethrow——v1.6.6/v1.6.7 两轮
/// 「已修」实际只加了同步 try-catch 与 unawaited，异步异常照样逃逸成
/// unhandled async exception（Hive 写盘失败时每个进度 tick 一条）。
///
/// 断言三件事：
/// 1. runZonedGuarded 内零未处理异常（异常被吞而不是逃逸）；
/// 2. 失败被记录成 warn 日志（「progress persist failed」）；
/// 3. 下一次进度 tick 照常执行（失败不中断热路径）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadController async error containment (W-🟡1)', () {
    test('progress tick: updateEpisode async failure is swallowed, '
        'logged, and next tick still runs', () async {
      final repo = _FailingUpdateRepository();
      final manager = _FakeDownloadManager();
      final controller = DownloadController(repo, manager, PluginsController());
      await controller.init();
      expect(manager.onProgress, isNotNull,
          reason: 'init() 必须把进度回调挂到 manager 上');

      final episode = DownloadEpisode(
        1,
        'EP1',
        0,
        DownloadStatus.downloading,
        0.5,
        100,
        50,
        '',
        '/tmp/download',
        'https://example.com/index.m3u8',
        null,
        '',
        0,
        'https://example.com/ep1',
      );
      repo.seed(DownloadRecord(
        100,
        '测试番剧',
        '',
        'testplugin',
        {1: episode},
        DateTime(2026, 1, 1),
      ));

      final unhandled = <Object>[];
      final printed = <String>[];
      await runZonedGuarded(
        () async {
          // 连续两个 tick：第二个证明「tick N 持久化失败」不会中断
          // tick N+1 的执行。
          manager.onProgress!('testplugin_100', 1, episode, 512.0);
          await Future<void>.delayed(Duration.zero);
          manager.onProgress!('testplugin_100', 1, episode, 512.0);
          // 多让出几轮事件循环，确保被丢弃的 Future 有机会完成并暴露
          // 未处理错误（若修复缺失，这里就会逃逸）。
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
        (error, stackTrace) => unhandled.add(error),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(unhandled, isEmpty,
          reason: 'updateEpisode 的异步 rethrow 必须被 catchError 吞掉，'
              '不能逃逸成 unhandled async exception');
      expect(repo.updateEpisodeCalls, 2,
          reason: '持久化失败不应中断后续进度 tick');
      expect(
        printed.any((line) => line.contains('progress persist failed')),
        isTrue,
        reason: '吞掉的异常必须留下 warn 级日志',
      );
    });

    test('_failEpisode path: updateEpisode async failure is swallowed '
        'and logged', () async {
      final repo = _FailingUpdateRepository();
      final manager = _FakeDownloadManager();
      final controller = DownloadController(repo, manager, PluginsController());
      await controller.init();

      final episode = DownloadEpisode(
        1,
        'EP1',
        0,
        DownloadStatus.paused,
        0.0,
        0,
        0,
        '',
        '',
        'https://example.com/index.m3u8',
        null,
        '',
        0,
        'https://example.com/ep1',
      );
      repo.seed(DownloadRecord(
        200,
        '测试番剧2',
        '',
        // 插件名与 retryDownload 传入的一致（_findPlugin 在空插件表里
        // 找不到它 → 走 _failEpisode 分支）。
        'missing-plugin',
        {1: episode},
        DateTime(2026, 1, 1),
      ));

      final unhandled = <Object>[];
      final printed = <String>[];
      await runZonedGuarded(
        () async {
          // 插件不存在 → retryDownload 走 _failEpisode →
          // unawaited(updateEpisode(...))，仓库抛错。
          await controller.retryDownload(
            bangumiId: 200,
            pluginName: 'missing-plugin',
            episodeNumber: 1,
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
        (error, stackTrace) => unhandled.add(error),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(unhandled, isEmpty,
          reason: '_failEpisode 的 updateEpisode 异步 rethrow 同样必须被'
              ' catchError 吞掉（v1.6.6 的 unawaited 不是错误处理）');
      expect(repo.updateEpisodeCalls, 1);
      expect(
        printed.any((line) => line.contains('failed to persist failure state')),
        isTrue,
        reason: '吞掉的异常必须留下 warn 级日志',
      );
    });
  });
}

/// 仓库 stub：updateEpisode 无条件异步抛错（模拟 Hive 写盘失败——
/// 真实仓库 catch 后 rethrow，异常只进返回的 Future）。
class _FailingUpdateRepository implements IDownloadRepository {
  int updateEpisodeCalls = 0;
  final Map<String, DownloadRecord> _records = {};

  void seed(DownloadRecord record) => _records[record.key] = record;

  @override
  Stream<void> get changes => Stream<void>.empty();

  @override
  List<DownloadRecord> getAllRecords() => _records.values.toList();

  @override
  DownloadRecord? getRecord(String key) => _records[key];

  @override
  Future<void> putRecord(DownloadRecord record) async {}

  @override
  Future<void> deleteRecord(String key) async {}

  @override
  Future<void> updateEpisode(
      String recordKey, int episodeNumber, DownloadEpisode episode) async {
    updateEpisodeCalls++;
    throw StateError('simulated hive write failure');
  }

  @override
  Future<void> deleteEpisode(String recordKey, int episodeNumber) async {}

  @override
  bool getForceAdBlocker() => false;

  @override
  DownloadRecord? getRecordByBangumiId(int bangumiId, String pluginName) =>
      _records['${pluginName}_$bangumiId'];

  @override
  DownloadEpisode? getEpisode(
          int bangumiId, String pluginName, int episodeNumber) =>
      _records['${pluginName}_$bangumiId']?.episodes[episodeNumber];

  @override
  List<DownloadEpisode> getCompletedEpisodes(
          int bangumiId, String pluginName) =>
      const [];

  @override
  DownloadEpisode? getEpisodeByUrl(
          int bangumiId, String pluginName, String episodePageUrl) =>
      null;
}

/// 下载管理器 stub：只保留 onProgress 回调的挂载能力。
class _FakeDownloadManager implements IDownloadManager {
  @override
  ProgressCallback? onProgress;

  @override
  bool isDownloading(String recordKey, int episodeNumber) => false;

  @override
  Future<void> enqueue(DownloadRequest request) async {}

  @override
  Future<void> enqueuePriority(DownloadRequest request) async {}

  @override
  void pause(String recordKey, int episodeNumber) {}

  @override
  Future<void> resume(DownloadRequest request) async {}

  @override
  void cancel(String recordKey, int episodeNumber) {}

  @override
  String? getLocalVideoPath(DownloadEpisode? episode) => null;

  @override
  Future<void> deleteEpisodeFiles(int bangumiId, String pluginName,
      int episodeNumber,
      {DownloadEpisode? episode}) async {}

  @override
  Future<void> deleteRecordFiles(int bangumiId, String pluginName,
      {DownloadRecord? record}) async {}

  @override
  double getSpeed(String recordKey, int episodeNumber) => 0.0;
}
