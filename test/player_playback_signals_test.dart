// v1.7.0（P0-1/P0-2）：播放器状态机竞态回归锁。
//
// P0-2（softStop 单飞 + 世代号守卫）行为测试：
//  - 双发 softStop 只执行一次 stop 序列（单飞共享 Future）；
//  - openMedia 等待在途软停 → 顺序固定「stop → open」，open 之后
//    绝无第二次 stop（旧竞态：迟到的 stop 把新集直接停掉）；
//  - 软停尾部复位绝不清掉 open 之后到达的首帧信号（旧竞态：
//    hasVideoParams 被迟到复位清掉 → 遮罩永远不撤 = 有声黑屏）。
//
// P0-1（自动连播定时器）源契约测试：
//  - 连播分支不再取消 playerTimer；
//  - 防重入标志 + completed 事件直通 + 换集重启定时器保险丝。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:miru/pages/player/controller/player_debug_controller.dart';
import 'package:miru/pages/player/controller/player_playback_controller.dart';
import 'package:miru/services/shaders/shader_asset_service.dart';
import 'package:miru/services/storage/storage.dart';
import 'dart:io';

/// 假 NativePlatform 的类型目标：media_kit 在 VM 上导出的
/// NativePlayer（real.dart）。
typedef NativePlatformShim = NativePlayer;

/// 假 Player：只实现 softStop/openMedia 路径触达的成员，其余经
/// noSuchMethod 兜底（media_kit 的 Player 是隐式接口）。
class _FakePlayer implements Player {
  _FakePlayer({this.stopDelay = Duration.zero});

  /// stop() 的人为延迟（模拟慢机 demuxer teardown）。
  final Duration stopDelay;

  /// 调用序列（判定 stop→open 顺序）。
  final List<String> calls = [];
  int get stopCalls => calls.where((c) => c == 'stop').length;
  int get openCalls => calls.where((c) => c == 'open').length;

  final _FakeNativePlatform _fakePlatform = _FakeNativePlatform();

  @override
  PlatformPlayer get platform => _fakePlatform;

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (stopDelay > Duration.zero) {
      await Future<void>.delayed(stopDelay);
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = false}) async {
    calls.add('open');
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假 NativePlatform：setProperty/command/waitFor* 全部即答。
/// （openMedia 里 `player.platform as NativePlayer` 的强转目标。）
class _FakeNativePlatform implements NativePlatformShim {
  final List<String> properties = [];

  @override
  Future<void> setProperty(String property, String value,
      {bool waitForInitialization = true}) async {
    properties.add('$property=$value');
  }

  @override
  Future<void> command(List<String> command,
      {bool waitForInitialization = true}) async {}

  @override
  Future<void> get waitForPlayerInitialization => Future<void>.value();

  @override
  Future<void> get waitForVideoControllerInitializationIfAttached =>
      Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
        return '/tmp/miru_p02_signals_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_p02_signals_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_p02_signals_test/hive');
    await GStorage.init();
  });

  PlayerPlaybackController newPlayback() => PlayerPlaybackController(
        shaderAssetService: ShaderAssetService(),
        debug: PlayerDebugController(),
        videoUrl: () => 'https://example.com/stream.m3u8',
        isLocalPlayback: () => false,
      );

  group('P0-2：softStop 单飞', () {
    test('双发 softStop 共享同一序列，stop 只执行一次', () async {
      final playback = newPlayback();
      final player = _FakePlayer(stopDelay: const Duration(milliseconds: 80));
      playback.debugInstallPlayerForTest(player);

      // 双发：changeEpisode 的 unawaited + init 的 await（旧双发竞态）。
      final a = playback.softStop();
      final b = playback.softStop();
      await Future.wait([a, b]);

      expect(player.stopCalls, 1,
          reason: '单飞：第二个 softStop 必须共享第一个的 Future，'
              '不得再跑一遍 stop 序列');
      expect(player.calls.contains('pause'), isTrue);
    });

    test('openMedia 等待在途软停：顺序固定 stop → open，open 后绝无 stop',
        () async {
      final playback = newPlayback();
      final player = _FakePlayer(stopDelay: const Duration(milliseconds: 120));
      playback.debugInstallPlayerForTest(player);

      // 换集：软停发起（不等待），随后 openMedia 进来。
      unawaited(playback.softStop());
      final opened = await playback.openMedia(
        player,
        httpHeaders: const {},
      );
      expect(opened, same(player), reason: 'openMedia 正常完成');
      expect(player.openCalls, 1);

      // 关键断言：open 之后再无 stop（旧竞态：迟到的 stop 序列把
      // 新集直接停掉——有声黑屏/永转圈的残余根因）。
      final openIndex = player.calls.indexOf('open');
      final lastStopIndex = player.calls.lastIndexOf('stop');
      expect(lastStopIndex, lessThan(openIndex),
          reason: '所有 stop 都必须在 open 之前完成');
      expect(player.stopCalls, 1);

      // 再等一个软停延迟窗口，确认没有迟到的 stop 落下。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.stopCalls, 1, reason: '迟到的第二次 stop 不得出现');
    });

    test('软停尾部复位不清掉 open 后的首帧信号（世代号守卫）', () async {
      final playback = newPlayback();
      final player = _FakePlayer(stopDelay: const Duration(milliseconds: 60));
      playback.debugInstallPlayerForTest(player);

      unawaited(playback.softStop());
      await playback.openMedia(player, httpHeaders: const {});

      // 模拟新集首帧（videoParams 事件到达）。
      playback.hasVideoParams = true;

      // 假如软停尾部在 open 之后才落下（旧竞态），hasVideoParams 会被
      // 清掉且 videoParams 对同一流只来一次 → 遮罩永远不撤。
      // 单飞 + 世代号守卫后：软停在 open 前全部完成，此处保持置位。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(playback.hasVideoParams, isTrue,
          reason: '迟到的软停复位不得清掉新集的首帧信号（有声黑屏根因）');
    });

    test('awaitPendingSoftStop 不重复发起软停（init 路径语义）', () async {
      final playback = newPlayback();
      final player = _FakePlayer(stopDelay: const Duration(milliseconds: 80));
      playback.debugInstallPlayerForTest(player);

      // changeEpisode 已发起；init 只等待。
      final inFlight = playback.softStop();
      await playback.awaitPendingSoftStop();
      await inFlight;
      expect(player.stopCalls, 1,
          reason: 'init 的 awaitPendingSoftStop 不得再发起第二次 stop 序列');
    });
  });

  group('P0-1：自动连播定时器（源契约）', () {
    final projectRoot = Directory.current;

    test('连播分支不再取消 playerTimer（常驻挂载下取消=永久停止）', () {
      final source = File.fromUri(projectRoot.uri
              .resolve('lib/pages/player/player_item.dart'))
          .readAsStringSync();
      expect(source.contains('playerTimer!.cancel()'), isFalse,
          reason: 'v1.6.7 起 PlayerItem 常驻挂载、initState 不再执行，'
              '取消定时器后没有任何路径重建它——进度条冻结/历史不写/'
              '弹幕停/连播不触发。防重入标志代替取消。');
      expect(source.contains('_autoNextInFlight'), isTrue,
          reason: '防重入标志必须在场');
      expect(source.contains('whenComplete(() {\n        _autoNextInFlight = false;'),
          isTrue, reason: 'changeEpisode 完成后必须复位防重入标志');
    });

    test('completed 事件直通 + 换集重启定时器保险丝在场', () {
      final itemSource = File.fromUri(projectRoot.uri
              .resolve('lib/pages/player/player_item.dart'))
          .readAsStringSync();
      expect(itemSource.contains('onCompleted.listen'), isTrue,
          reason: 'PlayerItem 必须订阅 completed 事件流（事件驱动连播）');
      expect(itemSource.contains('_maybeAutoAdvance'), isTrue,
          reason: '连播判定已抽出为共用方法');
      // 换集 → 重启定时器（保险丝）。
      expect(
          itemSource.contains('_restartPlayerTimer'), isTrue);

      final controllerSource = File.fromUri(projectRoot.uri
              .resolve('lib/pages/player/controller/player_playback_controller.dart'))
          .readAsStringSync();
      expect(controllerSource.contains('Stream<void> get onCompleted'), isTrue,
          reason: '播放控制器必须暴露 completed 事件流');
      expect(
          controllerSource.contains('player.stream.completed.listen'), isTrue,
          reason: 'ensurePlayer 必须订阅 mpv completed 流并广播');
    });

    test('连播判定的 roadList 边界检查在场（兜底换源替换 roadList）', () {
      final source = File.fromUri(projectRoot.uri
              .resolve('lib/pages/player/player_item.dart'))
          .readAsStringSync();
      expect(
          source.contains('playingSelection.road >= roadList.length'), isTrue,
          reason: '兜底换源 _applyFallbackContext 替换 roadList 后，'
              '旧 selection.road 可能越界（RangeError 打死定时拍）');
    });
  });
}
