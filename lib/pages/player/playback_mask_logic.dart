/// v1.6.8（F1b/F2/R-2/F3/R-12）：播放器遮罩/挂载状态机（纯函数）。
///
/// 播放页的可见性决策此前散在 video_page.playerBody / player_item 的
/// spinner / player_item_surface 三处，各自微妙的条件组合正是 v1.6.7
/// 「有声黑屏」「黑屏永转圈零入口」的病灶族：
///  - 遮罩条件乘了 `playback.loading` 因子 → 装配结束遮罩即撤，
///    [open→首帧] 裸黑屏无转圈（R-2 窗口 A/B）；
///  - `duration>0` 即时兑底 → HLS VOD 时长在清单解析即知、远早于
///    首帧，首帧信号被提前「伪装成立」（R-2 窗口 B）；
///  - PlayerItem 粘性挂载 + Stack 最上层不透明黑底 → 错误页/重试/
///    顶栏全被遮死（F3 回归）。
///
/// 这里把四组谓词收敛成纯函数，三处 UI 只做信号接线——状态机可用
/// 单测锁定（test/playback_mask_logic_test.dart 的五场景推演）。
library;

/// 「真正开始」：mpv 真实首帧信号（videoParams 宽高就绪）或纯音频
/// 延迟兑底信号（duration 已知 3s 后仍无首帧才置位）。
///
/// duration 不参与即时判定——HLS VOD 的 duration 在 demuxer 打开
/// 清单时即知、远早于首帧，v1.6.7 拿它即时背书导致遮罩提前撤下。
/// 两信号均为每集 sticky、换集复位（resetForInit/softStop），播放中
/// 暂停不会误亮遮罩。
bool playbackActuallyStarted({
  required bool hasVideoParams,
  required bool hasAudioOnlyFallback,
}) =>
    hasVideoParams || hasAudioOnlyFallback;

/// 页面级遮罩（转圈/错误页）可见性。
///
/// `!actuallyStarted` 不再乘 playback.loading 因子（R-2）：装配结束
/// （loading=false）到首帧之间遮罩保持覆盖——期间文案由
/// _ResolveStatusText 显示「已解析完成，正在缓冲视频…」。
bool playbackMaskVisible({
  required bool pageLoading,
  required bool actuallyStarted,
  String? errorMessage,
}) =>
    pageLoading || !actuallyStarted || errorMessage != null;

/// PlayerItem 挂载条件（v1.6.7 P-2 粘性 + v1.6.8 F3 错误态豁免）。
///
/// [assemblyLoading] = playback.loading（装配期）；[everStarted] 为
/// 页面会话粘性标志（首帧出现后置位，页面重建才归零）。
///
/// errorMessage 非空时豁免粘性：错误是本集终态（mpv 已停/未起、
/// video-params 已清、position=0），卸载 Video 无 vo 拆挂竞态风险；
/// 而 PlayerItem 是 Stack 最上层的不透明黑底，不卸载会把错误页/
/// 重试按钮/顶栏全部遮死（v1.6.7 回归：黑屏永转圈零入口）。
bool playerItemMounted({
  required bool assemblyLoading,
  required bool everStarted,
  String? errorMessage,
}) =>
    !((assemblyLoading && !everStarted) || errorMessage != null);

/// PlayerItem 内部 spinner 可见性（F2）：首帧前一律有「缓冲中」指示。
///
/// isBuffering 在 fork stop→START_FILE 的间隙会短暂翻 false，而
/// videoParams/纯音频兑底未到时画面还是黑的——转圈不能跟着熄灭
/// （有声黑屏的残留形态正是「spinner 熄灭 + 画面仍黑数秒」）。
bool playerItemSpinnerVisible({
  required bool isBuffering,
  required bool pageLoading,
  required bool hasVideoParams,
  required bool hasAudioOnlyFallback,
}) =>
    isBuffering || pageLoading || !(hasVideoParams || hasAudioOnlyFallback);
