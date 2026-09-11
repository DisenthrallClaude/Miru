import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/player/controller/player_debug_controller.dart';
import 'package:miru/pages/player/controller/player_playback_controller.dart';
import 'package:miru/services/shaders/shader_asset_service.dart';

/// v1.6.8（F2/R-2/F5）PlayerPlaybackController 信号语义单测：
///  - 纯音频延迟兜底（hasAudioOnlyFallback）：duration 已知后延迟置位、
///    首帧先到则取消、resetForInit 复位并取消挂起的定时器；
///  - PlaybackSessionOnceFlag（F5）：移动数据 toast 会话级去重。
///
/// 控制器构造不触碰平台通道（Player/openMedia 均不调用），延迟窗口
/// 经 @visibleForTesting 字段注入短值。
void main() {
  PlayerPlaybackController newPlayback() => PlayerPlaybackController(
        shaderAssetService: ShaderAssetService(),
        debug: PlayerDebugController(),
        videoUrl: () => 'https://example.com/stream.m3u8',
        isLocalPlayback: () => false,
      );

  group('纯音频延迟兜底（F2/R-2）', () {
    test('duration 已知后不即时置位，延迟窗口到点才置位', () async {
      final playback = newPlayback();
      playback.audioOnlyFallbackDelay = const Duration(milliseconds: 60);
      // 模拟 duration 流事件（demuxer 打开清单即知，早于首帧）。
      playback.duration = const Duration(minutes: 24);
      playback.debugScheduleAudioOnlyFallback();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(playback.hasAudioOnlyFallback, isFalse,
          reason: 'v1.6.7 的即时 duration 兜底会在这里提前撤遮罩——'
              '「出声→首帧」黑窗的根因');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(playback.hasAudioOnlyFallback, isTrue,
          reason: '3s（测试 60ms）窗口后仍无首帧 → 纯音频流放行遮罩');
      expect(playback.hasVideoParams, isFalse);
    });

    test('首帧信号先到：兜底预约被取消，视频流永远等真实首帧', () async {
      final playback = newPlayback();
      playback.audioOnlyFallbackDelay = const Duration(milliseconds: 60);
      playback.duration = const Duration(minutes: 24);
      playback.debugScheduleAudioOnlyFallback();
      // 首帧到达（videoParams 宽高就绪）。
      playback.hasVideoParams = true;

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(playback.hasAudioOnlyFallback, isFalse,
          reason: 'videoParams 先到则取消兜底定时器');
      expect(playback.hasVideoParams, isTrue);
    });

    test('resetForInit 复位两信号并取消挂起的兜底定时器', () async {
      final playback = newPlayback();
      playback.audioOnlyFallbackDelay = const Duration(milliseconds: 60);
      playback.duration = const Duration(minutes: 24);
      // 挂起一个兜底预约（未到点）。
      playback.debugScheduleAudioOnlyFallback();
      playback.hasVideoParams = true;

      playback.resetForInit();
      expect(playback.hasVideoParams, isFalse);
      expect(playback.hasAudioOnlyFallback, isFalse);
      expect(playback.duration, Duration.zero);

      // 换集后挂起的旧定时器不得复活（否则旧集的兜底会污染新集信号）。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(playback.hasAudioOnlyFallback, isFalse,
          reason: 'resetForInit 取消挂起的兜底定时器');
    });

    test('已置位的兜底在换集（resetForInit）后重新等待新集信号', () async {
      final playback = newPlayback();
      playback.audioOnlyFallbackDelay = const Duration(milliseconds: 40);
      playback.duration = const Duration(minutes: 24);
      playback.debugScheduleAudioOnlyFallback();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(playback.hasAudioOnlyFallback, isTrue);

      playback.resetForInit();
      expect(playback.hasAudioOnlyFallback, isFalse, reason: '换集后重新等首帧/纯音频判定');
    });
  });

  group('PlaybackSessionOnceFlag（F5 移动数据 toast 会话级去重）', () {
    test('会话内只放行一次', () {
      final flag = PlaybackSessionOnceFlag();
      expect(flag.consumeOnce(), isTrue, reason: '第一次 openMedia 提示');
      expect(flag.consumeOnce(), isFalse, reason: '换集/连播/换源不再提示');
      expect(flag.consumeOnce(), isFalse);
    });

    test('新会话（新实例）重新放行——实例生命周期即会话边界', () {
      final first = PlaybackSessionOnceFlag();
      expect(first.consumeOnce(), isTrue);
      expect(first.consumeOnce(), isFalse);

      final second = PlaybackSessionOnceFlag();
      expect(second.consumeOnce(), isTrue,
          reason: '重进播放页 = 新的 PlayerPlaybackController 实例，'
              '提示重新放行一次');
    });
  });
}
