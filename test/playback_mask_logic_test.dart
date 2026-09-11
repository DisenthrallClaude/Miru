import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/player/playback_mask_logic.dart';

/// v1.6.8（F1b/F2/R-2/F3/R-12）遮罩状态机单测。
///
/// 锁定 playback_mask_logic.dart 四组纯谓词在五个场景下的状态流转：
/// 首集起播 / 换集 / 换集失败→错误页→重试 / 纯音频 / 播放中暂停缓冲。
/// 信号定义（PlayerPlaybackController）：
///  - hasVideoParams：mpv 首帧（videoParams 宽高就绪），每集 sticky；
///  - hasAudioOnlyFallback：duration 已知 3s 后仍无首帧才置位（纯音频
///    兜底），每集 sticky；
///  - duration 不再参与即时判定（v1.6.7 回归：HLS VOD 时长远早于首帧，
///    拿它即时背书会把「出声→首帧」黑窗提前放出）。
void main() {
  group('playbackActuallyStarted（F2/R-2 信号拆分）', () {
    test('duration 不参与：两信号皆无时即使 duration>0 也不算开始', () {
      expect(
        playbackActuallyStarted(
          hasVideoParams: false,
          hasAudioOnlyFallback: false,
        ),
        isFalse,
        reason: 'v1.6.7 拿 duration>0 即时兜底导致遮罩提前撤下（R-2 窗口 B）',
      );
    });

    test('首帧信号单独成立', () {
      expect(
        playbackActuallyStarted(
          hasVideoParams: true,
          hasAudioOnlyFallback: false,
        ),
        isTrue,
      );
    });

    test('纯音频兜底信号单独成立', () {
      expect(
        playbackActuallyStarted(
          hasVideoParams: false,
          hasAudioOnlyFallback: true,
        ),
        isTrue,
      );
    });
  });

  group('场景 1：首集起播（open→首帧全程有指示）', () {
    test('解析中/装配中/装配结束→首帧之间遮罩常亮，首帧到达才撤', () {
      // t0 进页：页面 loading（解析中）。
      expect(
        playbackMaskVisible(pageLoading: true, actuallyStarted: false),
        isTrue,
      );
      // t1 解析完成、装配完成（playback.loading=false）——v1.6.7 在这里
      // 撤遮罩（loading 因子），[open→首帧] 裸黑屏；v1.6.8 保持覆盖。
      expect(
        playbackMaskVisible(pageLoading: false, actuallyStarted: false),
        isTrue,
        reason: 'R-2：去掉 loading 因子，装配结束→首帧之间遮罩不撤',
      );
      // t2 mpv 报出 duration（清单解析即知）——仍不算开始。
      expect(
        playbackMaskVisible(pageLoading: false, actuallyStarted: false),
        isTrue,
      );
      // t3 首帧（videoParams 宽高就绪）→ 撤遮罩。
      final started = playbackActuallyStarted(
        hasVideoParams: true,
        hasAudioOnlyFallback: false,
      );
      expect(
        playbackMaskVisible(pageLoading: false, actuallyStarted: started),
        isFalse,
      );
    });

    test('首帧前 PlayerItem 自带 spinner（有声黑窗内转圈不熄灭）', () {
      // fork stop→START_FILE 间隙 isBuffering 会短暂翻 false——v1.6.8
      // 加了「未开始」因子，转圈不跟着熄灭。
      expect(
        playerItemSpinnerVisible(
          isBuffering: false,
          pageLoading: false,
          hasVideoParams: false,
          hasAudioOnlyFallback: false,
        ),
        isTrue,
      );
      // 首帧后回到纯 buffering 语义。
      expect(
        playerItemSpinnerVisible(
          isBuffering: false,
          pageLoading: false,
          hasVideoParams: true,
          hasAudioOnlyFallback: false,
        ),
        isFalse,
      );
    });
  });

  group('场景 2：换集（PlayerItem 粘性 + 遮罩全程）', () {
    test('换集期间 PlayerItem 常驻，遮罩从解析盖到新首帧', () {
      // 前提：第 1 集已真正开播（页面会话粘性标志置位）。
      const everStarted = true;
      // t0 点换集：软停使 playback.loading=true、两信号复位。
      expect(
        playerItemMounted(
          assemblyLoading: true,
          everStarted: everStarted,
          errorMessage: null,
        ),
        isTrue,
        reason: 'P-2 粘性：换集不卸载 Video（避免 vo 拆挂 + seek 竞态）',
      );
      // t1 解析完成、装配完成（loading=false）、新首帧未到：遮罩仍亮。
      expect(
        playbackMaskVisible(pageLoading: false, actuallyStarted: false),
        isTrue,
      );
      // t2 新首帧 → 撤遮罩。
      expect(
        playbackMaskVisible(
          pageLoading: false,
          actuallyStarted: true,
        ),
        isFalse,
      );
    });

    test('换源（自动兜底换源）同构：粘性 + 全程遮罩', () {
      const everStarted = true;
      expect(
        playerItemMounted(
          assemblyLoading: true,
          everStarted: everStarted,
          errorMessage: null,
        ),
        isTrue,
      );
      expect(
        playbackMaskVisible(pageLoading: true, actuallyStarted: false),
        isTrue,
      );
    });
  });

  group('场景 3：失败终态与重试（F3 errorMessage 豁免）', () {
    test('换集解析失败：错误页遮罩亮 + PlayerItem 豁免粘性卸载', () {
      // v1.6.7 回归：PlayerItem 是 Stack 最上层的不透明黑底，错误页/
      // 重试按钮/顶栏全被遮死（黑屏永转圈零入口）。v1.6.8 豁免。
      expect(
        playerItemMounted(
          assemblyLoading: false,
          everStarted: true,
          errorMessage: '视频解析超时，请重试',
        ),
        isFalse,
        reason: 'F3：errorMessage 非空时豁免粘性——错误是本集终态，'
            '卸载 Video 无 vo 竞态风险',
      );
      expect(
        playbackMaskVisible(
          pageLoading: false,
          actuallyStarted: false,
          errorMessage: '视频解析超时，请重试',
        ),
        isTrue,
        reason: '错误页仍然渲染（遮罩层负责）',
      );
    });

    test('播放层失败终态（R-12 onPlaybackDead）同款：错误页 + 豁免', () {
      const message = '播放失败，请尝试更换线路或视频来源';
      expect(
        playerItemMounted(
          assemblyLoading: false,
          everStarted: true,
          errorMessage: message,
        ),
        isFalse,
      );
      expect(
        playbackMaskVisible(
          pageLoading: false,
          actuallyStarted: true, // 首帧可能已出过（换集后打不开）
          errorMessage: message,
        ),
        isTrue,
      );
    });

    test('重试：errorMessage 清空后恢复粘性挂载（与正常链路一致）', () {
      // changeEpisode → _beginEpisodeSwitch 清 errorMessage、置 loading。
      expect(
        playerItemMounted(
          assemblyLoading: true,
          everStarted: true,
          errorMessage: null,
        ),
        isTrue,
      );
      expect(
        playbackMaskVisible(pageLoading: true, actuallyStarted: false),
        isTrue,
      );
    });

    test('首集未开播即失败：PlayerItem 本来就未挂载（无回归）', () {
      expect(
        playerItemMounted(
          assemblyLoading: true,
          everStarted: false,
          errorMessage: null,
        ),
        isFalse,
      );
    });
  });

  group('场景 4：纯音频流（延迟兜底的正确退出条件）', () {
    test('duration 已知 + 3s 无首帧 → 兜底信号放行遮罩', () {
      // duration 已知（清单解析即知）但兜底未置位：遮罩保持。
      var actuallyStarted = playbackActuallyStarted(
        hasVideoParams: false,
        hasAudioOnlyFallback: false,
      );
      expect(actuallyStarted, isFalse);
      // 3s 兜底到点（由 PlayerPlaybackController 的定时器置位）。
      actuallyStarted = playbackActuallyStarted(
        hasVideoParams: false,
        hasAudioOnlyFallback: true,
      );
      expect(actuallyStarted, isTrue);
      expect(
        playbackMaskVisible(
          pageLoading: false,
          actuallyStarted: actuallyStarted,
        ),
        isFalse,
        reason: '纯音频流不被遮罩卡死（有正确的退出条件）',
      );
    });
  });

  group('场景 5：播放中暂停/缓冲（sticky 信号不误亮遮罩）', () {
    test('首帧已出后暂停、缓冲均不回遮罩', () {
      const started = true;
      expect(
        playbackMaskVisible(
          pageLoading: false,
          actuallyStarted: started,
          errorMessage: null,
        ),
        isFalse,
      );
      // 播放中缓冲：PlayerItem 的 spinner 由 isBuffering 承担。
      expect(
        playerItemSpinnerVisible(
          isBuffering: true,
          pageLoading: false,
          hasVideoParams: true,
          hasAudioOnlyFallback: false,
        ),
        isTrue,
      );
      expect(
        playerItemSpinnerVisible(
          isBuffering: false,
          pageLoading: false,
          hasVideoParams: true,
          hasAudioOnlyFallback: false,
        ),
        isFalse,
      );
    });
  });
}
