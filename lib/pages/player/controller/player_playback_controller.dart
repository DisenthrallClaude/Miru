// ignore_for_file: library_private_types_in_public_api

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/pages/player/controller/player_debug_controller.dart';
import 'package:miru/pages/player/controller/player_super_resolution.dart';
import 'package:miru/services/shaders/shader_asset_service.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/network/proxy_utils.dart';
import 'package:miru/services/network/system_proxy_service.dart';
import 'package:miru/services/player/playback_cache_policy.dart';
import 'package:miru/services/player/player_screenshot_service.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';
import 'package:miru/utils/device.dart';
import 'package:miru/utils/media.dart';
import 'package:miru/services/platform/platform_environment_service.dart';

part 'player_playback_controller.g.dart';

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

final class _OwnedPlayer {
  _OwnedPlayer(this.player);

  final Player player;
  Future<void>? _disposeFuture;

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      MiruLogger().e(
        'PlayerPlaybackController: failed to dispose media player',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await player.stop();
      } catch (_) {}
    }
  }
}

abstract class _PlayerPlaybackController with Store {
  _PlayerPlaybackController({
    required this.shaderAssetService,
    required this.debug,
    required this.videoUrl,
    required this.isLocalPlayback,
  });

  final ShaderAssetService shaderAssetService;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final bool Function() isLocalPlayback;
  final PlayerScreenshotService screenshotService =
      const PlayerScreenshotService();
  late final PlaybackCachePolicy cachePolicy = PlaybackCachePolicy(
    isLocalPlayback: isLocalPlayback,
    currentPlayer: () => mediaPlayer,
  );

  _OwnedPlayer? _ownedPlayer;
  Player? get mediaPlayer => _ownedPlayer?.player;
  VideoController? videoController;

  /// 播放态流订阅（buffering/playing）：即时驱动 MobX 观察量，
  /// stop() 时统一取消。
  final List<StreamSubscription> _playbackStateSubscriptions = [];

  /// 预取挂起写入串行化：生命周期快速翻转时保证后写胜出。
  final AsyncSerialQueue _prefetchWrites = AsyncSerialQueue();
  bool _prefetchSuspendWanted = false;

  // ---------------- 网络播放稳定性（v1.3.1） ----------------
  //
  // 针对聚合源 HLS 直连常见的不稳定（分片请求被 CDN 重置、连接抖动、
  // 假 EOF 误触发自动连播），做四层保守加固：
  //   1) ffmpeg 层 HTTP 自动重连（仅失败连接生效，正常播放零影响）
  //   2) 更大的前向缓冲余量（磁盘缓存有 1.5G 上限兜底，纯缓冲策略）
  //   3) 播放中流错误 → 同一播放器原地重开、续播当前位置（每集限 2 次）
  //   4) 流错误造成的假 EOF 不再触发自动连播
  // 不改动解码器、渲染器、音频输出等任何已验证路径。

  /// 前向缓冲目标（mpv 默认 10s，弱网源不够用）。
  /// 播放稳定后（buffer ≥ 15s 且 playing）由
  /// [_maybePromoteBuffering] 从起播值提升到这里的稳定值。
  static const String _cacheSecsNetwork = '120';

  /// demuxer 预读窗口（mpv 默认 1s，CDN 慢时极易卡顿）。
  /// 同上，稳定后提升。
  static const String _readaheadSecsNetwork = '10';

  /// 起播阶段前向缓冲（§1.7）：mpv 默认 10s，大窗口会拖慢出画。
  static const String _cacheSecsStartup = '10';

  /// 起播阶段 demuxer 预读窗口（§1.7）：起播后首帧优先。
  static const String _readaheadSecsStartup = '3';

  /// 缓冲提升阈值：首帧后 buffer 达到这个值且 playing 时把
  /// cache-secs/readahead 拉高到稳定值（仅执行一次，每集重置）。
  static const Duration _bufferPromoteThreshold = Duration(seconds: 15);

  /// 本集是否已执行过缓冲提升。
  bool _bufferPromoted = false;

  /// 单集自动恢复上限，防止死链循环重开。
  static const int _maxAutoRecoveries = 2;

  /// 恢复动作之间的最小间隔，吞掉分片失败的错误风暴。
  static const Duration _recoveryCooldown = Duration(seconds: 10);

  /// 最近一次流错误时间。用于把「错误导致的假 EOF」与正常播完区分开。
  DateTime? _lastStreamErrorAt;

  /// 当前集已用掉的自动恢复次数（每次 createVideoController 重置）。
  int _recoveryCount = 0;

  /// 上次恢复动作时间（冷却窗口）。
  DateTime? _lastRecoveryAt;

  /// 最近一次 open 使用的请求头，恢复时原样带上（Referer 等防盗链头缺失会 403）。
  Map<String, String> _lastHttpHeaders = const {};

  // ---------------- 秒开链路（v1.5.0）：本地代理 + 直连兑底 ----------------

  /// 原始直链：videoUrl() 是本地代理地址时，代理打开失败用它重开。
  String? _directVideoUrl;

  /// 实际正在播放的地址（代理或直连），恢复重开时用。
  String? _effectiveUrl;

  /// 直连兑底已尝试过（防止循环重开）。
  bool _directFallbackAttempted = false;

  /// 最近一次错误 toast 时间：错误风暴下（瞬时错误成串出现）
  /// 避免同屏连拍多条报错。
  DateTime? _lastErrorToastAt;

  /// 错误 toast 最小间隔。
  static const Duration _errorToastCooldown = Duration(seconds: 8);

  /// 距离结尾还有 30s 以上却收到 completed，且 10s 内出现过流错误，
  /// 判定为网络中断造成的假 EOF——不应触发自动连播。
  bool get isAbnormalEnd {
    final at = _lastStreamErrorAt;
    if (at == null) return false;
    if (DateTime.now().difference(at) > const Duration(seconds: 10)) {
      return false;
    }
    final d = playerDuration;
    final p = playerPosition;
    if (d <= Duration.zero) return false;
    return d - p > const Duration(seconds: 30);
  }

  /// 是否还允许自动恢复（未超上限、不在冷却期）。
  bool get canAutoRecover =>
      _recoveryCount < _maxAutoRecoveries &&
      (_lastRecoveryAt == null ||
          DateTime.now().difference(_lastRecoveryAt!) >= _recoveryCooldown);

  /// 假 EOF 分支专用：秒级轮询会连拍，用冷却窗口去重。
  bool _abnormalRecoveryInFlight = false;

  /// 800ms 复检的在途标记（按播放器实例）：错误风暴下同一实例只排程
  /// 一个复检，换集后的新实例不受旧复检压制。
  Player? _recoveryCheckInFlightFor;

  /// 异常 EOF 的恢复入口（由 player_item 的轮询触发）。
  ///
  /// 走独立的在途标记 + 冷却记账，重复触发直接返回；
  /// 恢复用尽后由调用方回落到原有的自动连播逻辑兜底。
  Future<void> recoverForAbnormalEnd() async {
    if (_abnormalRecoveryInFlight) return;
    if (!canAutoRecover) return;
    _abnormalRecoveryInFlight = true;
    _lastRecoveryAt = DateTime.now();
    _recoveryCount++;
    try {
      // 立刻清掉 completed，避免下一拍轮询再次进入完成分支。
      completed = false;
      await recoverPlayback();
    } finally {
      _abnormalRecoveryInFlight = false;
    }
  }

  /// 错误回调里判定是否值得自动恢复：仅网络播放、且播放器处于
  /// 播放/缓冲的活跃状态（用户主动暂停或已换集时绝不打扰）。
  void _maybeScheduleAutoRecovery(Player player) {
    if (!isCurrentPlayer(player)) return;
    if (isLocalPlayback()) return;
    if (playerCompleted) return;
    if (!playerPlaying && !playerBuffering) return;
    if (!canAutoRecover) return;
    if (_recoveryCheckInFlightFor != null &&
        identical(_recoveryCheckInFlightFor, player)) {
      return;
    }
    _recoveryCheckInFlightFor = player;
    // 冷却窗口从排程时刻起算：同时吞掉复检窗口内同实例的错误风暴。
    _lastRecoveryAt = DateTime.now();
    // 抖动场景下错误是成串来的：稍等片刻让 demuxer 先自愈，
    // 仍然失败才真正重开流。
    Future<void>.delayed(const Duration(milliseconds: 800), () async {
      if (identical(_recoveryCheckInFlightFor, player)) {
        _recoveryCheckInFlightFor = null;
      }
      final current = mediaPlayer;
      if (!identical(current, player) || playerCompleted) return;
      if (playerPlaying && !playerBuffering && playerPosition > Duration.zero) {
        return; // 已自行恢复——配额不扣，自愈不该消耗恢复次数
      }
      // 确认执行恢复才递增配额（v1.5.3）：此前在排程时预扣，长会话中
      // 两起相隔超过 10s 的自愈型抖动即可烧完 2 次配额，之后真正的
      // 断流反而失去原地重开保护。
      _recoveryCount++;
      await recoverPlayback();
    });
  }

  /// 瞬时错误提示：延迟数秒后复检播放状态。
  ///
  /// ffmpeg 自动重连（reconnect_streamed）生效期间，mpv 依旧会把
  /// 每个 CDN 抖动/分片失败抛到错误流——播放实际毫无影响。立刻弹
  /// 报错只会让用户以为出了问题。因此等 3 秒再判定：播放仍在正常
  /// 推进 = 已自愈，静默记日志；真的卡死才提示用户（带冷却去重）。
  void _showTransientErrorToast(Player player, Object event) {
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!isCurrentPlayer(player)) return;
      if (playerCompleted) return;
      if (playerPlaying && !playerBuffering && playerPosition > Duration.zero) {
        MiruLogger()
            .i('PlayerController: transient error self-healed ${videoUrl()}');
        return; // 播放仍在推进，错误已被重连/重试消化掉
      }
      final now = DateTime.now();
      final last = _lastErrorToastAt;
      if (last != null && now.difference(last) < _errorToastCooldown) return;
      _lastErrorToastAt = now;
      // toast 不外泄内部 URL（本地代理地址是 127.0.0.1 长串，既不可读
      // 也不可操作）；完整错误与 URL 已记入日志，只保留截断的摘要。
      final detail = event.toString();
      final brief = detail.length > 64 ? '${detail.substring(0, 64)}…' : detail;
      MiruDialog.showToast(
          message: '播放器内部错误 $brief',
          duration: const Duration(seconds: 5),
          showActionButton: true);
    });
  }

  /// 原地重开当前流并续播到中断位置。
  ///
  /// 复用同一个播放器实例：demuxer-lavf-format=hls、音频输出、
  /// 代理等 init 期设置的属性全部保留，只重开媒体本身。
  Future<void> recoverPlayback() async {
    final player = mediaPlayer;
    if (player == null) return;
    try {
      final pos = playerPosition;
      final resumeFrom = pos > const Duration(seconds: 5)
          ? pos - const Duration(seconds: 2) // 退 2s 覆盖缓冲边界
          : (startOffset > 0 ? Duration(seconds: startOffset) : Duration.zero);
      // 恢复进行中的提示与「错误提示」开关联动（v1.5.3）：关掉提示的
      // 用户不想被播放错误族的 toast 打扰，恢复动作本身照常执行。
      if (GStorage.getSetting<bool>(SettingsKeys.showPlayerError)) {
        MiruDialog.showToast(message: '网络波动，正在恢复播放…');
      }
      MiruLogger().w(
          'PlayerController: auto recovering stream at $pos (${videoUrl()})');
      await player.open(
        Media(_effectiveUrl ?? videoUrl(),
            start: resumeFrom, httpHeaders: _lastHttpHeaders),
        play: true,
      );
    } catch (e) {
      MiruLogger().w('PlayerController: auto recovery failed', error: e);
    }
  }
  // ---------------- 网络播放稳定性结束 ----------------

  /// Android 后台会切断网络访问；预取中的 demuxer 会烧完 ffmpeg 的
  /// 重连/分片重试并把流标记为 EOF，回前台后播放永久卡住。
  /// 挂起时把预读窗口归零，不再发起新请求，已缓冲数据仍可用；
  /// 恢复值与本控制器的网络播放默认值保持一致（见上方常量）。
  /// （同步自上游 Kazumi 84043d5）
  Future<void> setPrefetchSuspended(bool suspended) async {
    if (!Platform.isAndroid) {
      return;
    }
    _prefetchSuspendWanted = suspended;
    await _prefetchWrites.run(() async {
      final wanted = _prefetchSuspendWanted;
      final player = mediaPlayer;
      if (player == null) {
        return;
      }
      try {
        final pp = player.platform as NativePlayer;
        // 恢复值跟随当前阶段（§1.7）：未提升前回到起播值，
        // 已提升回到稳定值——后台回来不会越级拉大缓冲。
        await pp.setProperty('cache-secs',
            wanted ? '0' : (isLocalPlayback() ? '36000' : _currentCacheSecs));
        if (!isCurrentPlayer(player)) {
          return;
        }
        await pp.setProperty('demuxer-readahead-secs',
            wanted ? '0' : (isLocalPlayback() ? '1' : _currentReadaheadSecs));
      } catch (e) {
        MiruLogger().w(
          'PlayerController: failed to ${wanted ? 'suspend' : 'resume'} demuxer prefetch',
          error: e,
        );
      }
    });
  }

  bool hAenable = true;
  late String hardwareDecoder;
  bool androidEnableOpenSLES = true;
  bool autoPlay = true;
  bool playerDebugMode = false;
  int buttonSkipTime = 80;
  int arrowKeySkipTime = 10;

  /// 历史记录传入的 offset
  int startOffset = 0;

  /// 当前超分辨率模式
  @observable
  SuperResolutionMode superResolutionMode = SuperResolutionMode.off;

  @observable
  double volume = -1;

  /// 手势调节时的精确音量，避免 UI 节流导致累计误差
  double preciseVolume = -1;

  @observable
  bool loading = true;
  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;
  @observable
  double playerSpeed = 1.0;

  bool isCurrentPlayer(Player player) {
    return identical(mediaPlayer, player);
  }

  Future<Player?> _discardIfNotCurrent(_OwnedPlayer candidate) async {
    if (identical(_ownedPlayer, candidate)) {
      return candidate.player;
    }
    await candidate.dispose();
    return null;
  }

  Future<void> _cancelDebugInfo() async {
    try {
      await debug.cancel();
    } catch (_) {}
  }

  /// 当前阶段应使用的 cache-secs（§1.7）。
  String get _currentCacheSecs =>
      _bufferPromoted ? _cacheSecsNetwork : _cacheSecsStartup;

  /// 当前阶段应使用的 demuxer-readahead-secs（§1.7）。
  String get _currentReadaheadSecs =>
      _bufferPromoted ? _readaheadSecsNetwork : _readaheadSecsStartup;

  /// 播放稳定后的缓冲提升（§1.7）：首个 buffer ≥ 15s 且 playing 的
  /// 时刻把 cache-secs/readahead 从起播值拉到稳定值，仅执行一次。
  /// 挂起期间（后台/计量网绪）不执行，恢复后由后续 buffer 事件再触发。
  void _maybePromoteBuffering(Player player, Duration value) {
    if (_bufferPromoted) return;
    if (_prefetchSuspendWanted) return;
    if (value < _bufferPromoteThreshold) return;
    if (!playerPlaying) return;
    if (isLocalPlayback()) return;
    if (!isCurrentPlayer(player)) return;
    _bufferPromoted = true;
    unawaited(_prefetchWrites.run(() async {
      if (!isCurrentPlayer(player)) return;
      try {
        final pp = player.platform as NativePlayer;
        await pp.setProperty('cache-secs', _cacheSecsNetwork);
        if (!isCurrentPlayer(player)) return;
        await pp.setProperty(
            'demuxer-readahead-secs', _readaheadSecsNetwork);
        MiruLogger()
            .i('PlayerController: buffer promoted (cache-secs=120, readahead=10)');
      } catch (e) {
        MiruLogger().w('PlayerController: buffer promote failed', error: e);
      }
    }));
  }

  @action
  void resetForInit() {
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
    startOffset = 0;
    _directVideoUrl = null;
    _effectiveUrl = null;
    _directFallbackAttempted = false;
    _bufferPromoted = false;
  }

  /// 设置秒开链路的直连兑底地址（由 PlayerController.init 传入）。
  void setDirectFallbackUrl(String? url) {
    _directVideoUrl = (url != null && url.isNotEmpty) ? url : null;
  }

  /// 本地代理打开失败时用原始直链原地重开（仅一次）。
  /// 返回 true 表示已接管（无需再提示用户换源）。
  bool _attemptDirectFallback(Player player) {
    final direct = _directVideoUrl;
    if (direct == null || direct == videoUrl()) {
      return false;
    }
    if (_directFallbackAttempted) {
      return false;
    }
    if (!isCurrentPlayer(player)) {
      return false;
    }
    _directFallbackAttempted = true;
    _effectiveUrl = direct;
    MiruLogger().w(
        'PlayerController: local proxy failed to open, retrying with direct url');
    unawaited(player.open(
      Media(direct,
          start: Duration(seconds: startOffset),
          httpHeaders: _lastHttpHeaders),
      play: true,
    ));
    return true;
  }

  /// 本次会话是否从距结尾 [nearEndWatchedThreshold] 以内的位置起播。
  /// 这样的"播放完成"并非真正看完，应从头重播而非切下一集
  bool get resumedNearEnd {
    if (startOffset <= 0 || duration <= Duration.zero) {
      return false;
    }
    return Duration(seconds: startOffset) >= duration - nearEndWatchedThreshold;
  }

  /// 从头重播当前视频。[startOffset] 在重播落地后才归零，
  /// 避免自动连播在此期间抢先触发
  Future<void> restartFromBeginning() async {
    final player = mediaPlayer;
    if (player == null) {
      return;
    }
    try {
      await player.seek(Duration.zero);
      if (!isCurrentPlayer(player)) {
        return;
      }
      await player.play();
      startOffset = 0;
    } catch (e) {
      MiruLogger()
          .w('PlayerController: failed to restart from beginning', error: e);
    }
  }

  bool get playerPlaying {
    try {
      return mediaPlayer?.state.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerBuffering {
    try {
      return mediaPlayer?.state.buffering ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerCompleted {
    try {
      return mediaPlayer?.state.completed ?? false;
    } catch (_) {
      return false;
    }
  }

  double get playerVolume {
    try {
      return mediaPlayer?.state.volume ?? volume;
    } catch (_) {
      return volume;
    }
  }

  Duration get playerPosition {
    try {
      return mediaPlayer?.state.position ?? currentPosition;
    } catch (_) {
      return currentPosition;
    }
  }

  Duration get playerBuffer {
    try {
      return mediaPlayer?.state.buffer ?? buffer;
    } catch (_) {
      return buffer;
    }
  }

  Duration get playerDuration {
    try {
      return mediaPlayer?.state.duration ?? duration;
    } catch (_) {
      return duration;
    }
  }

  // ---------------- 装配辅助（v1.5.3） ----------------

  /// demuxer-cache-dir 的临时目录进程内不变：缓存结果后，换集装配
  /// 不再重复走 path_provider 平台通道往返。
  static String? _cachedPlayerTempPath;

  Future<String> getPlayerTempPathCached() async {
    final cached = _cachedPlayerTempPath;
    if (cached != null) {
      return cached;
    }
    final path = await getPlayerTempPath();
    _cachedPlayerTempPath = path;
    return path;
  }

  /// Android 音频输出装配（volume-max + ao）。
  Future<void> _applyAndroidAudioProperties(NativePlayer pp) async {
    if (!Platform.isAndroid) {
      return;
    }
    await pp.setProperty("volume-max", "100");
    await pp.setProperty(
        "ao", androidEnableOpenSLES ? "opensles" : "audiotrack");
  }

  /// mpv 网络代理装配：用户代理优先，未配置时跟随系统代理。
  Future<void> _applyProxyProperty(NativePlayer pp) async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (proxyEnable) {
      final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
      final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
      if (formattedProxy != null) {
        await pp.setProperty("http-proxy", formattedProxy);
        MiruLogger().i('Player: HTTP 代理设置成功 $formattedProxy');
      }
      return;
    }
    if (SystemProxyService.isActive) {
      final proxy = SystemProxyService.proxyFor('https');
      if (proxy != null) {
        await pp.setProperty("http-proxy", 'http://${proxy.$1}:${proxy.$2}');
        MiruLogger().i('Player: 跟随系统代理 http://${proxy.$1}:${proxy.$2}');
      }
    }
  }

  /// HLS 起播判定：与 hybrid 解析服务的宽松判定对齐——
  /// `format == hls || 去掉 query/fragment 后 URL 以 .m3u8 结尾`。
  /// 走本地代理时 [url] 是 127.0.0.1 代理地址（不含 .m3u8 后缀），
  /// 此时再回退用原始直链判定。
  bool _isHlsPlayback(VideoSourceFormat format, String url) {
    if (format == VideoSourceFormat.hls) {
      return true;
    }
    final direct = _directVideoUrl;
    final candidates =
        (direct == null || direct == url) ? [url] : [url, direct];
    for (final candidate in candidates) {
      final path = candidate.split('#').first.split('?').first.toLowerCase();
      if (path.endsWith('.m3u8')) {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 单例装配（阶段 1 / §2.1）：ensurePlayer（幂等）+ openMedia（每集）
  // ---------------------------------------------------------------------------

  /// 确保播放器内核就绪（幂等，§2.1）。
  ///
  /// 视频页生命周期内只创建一次 Player + VideoController：
  /// - Player：debug 挂钩、demuxer-cache-dir、af/ao、http-proxy、音轨、
  ///   错误监听与播放态流订阅（订阅随实例注册一次，[softStop] 不取消）；
  /// - VideoController：渲染器选择（gpu-next/gpu/mediacodec_embed）+ 纹理。
  ///
  /// 换集只调 [openMedia]（同实例 open），纹理常驻不再黑屏，
  /// 300~900ms 的实例重建 + 全量属性重下发只付一次。
  /// 渲染/解码设置在创建期读取——修改需重进视频页生效（§2.1(c)）。
  /// 真正销毁只在 [stop]（离开视频页 / beginShutdown）。
  Future<Player?> ensurePlayer(
    bool adBlockerEnabled, {
    required bool Function() canInstall,
  }) async {
    // 幂等：实例常驻（换集软停后直接复用）
    final existing = _ownedPlayer;
    if (existing != null) {
      return existing.player;
    }
    if (!canInstall()) {
      return null;
    }

    // 渲染/解码设置在创建期读取一次
    hAenable = GStorage.getSetting(SettingsKeys.hAenable);
    androidEnableOpenSLES =
        GStorage.getSetting(SettingsKeys.androidEnableOpenSLES);
    hardwareDecoder = GStorage.getSetting(SettingsKeys.hardwareDecoder);
    playerDebugMode = GStorage.getSetting(SettingsKeys.playerDebugMode);

    final candidate = _OwnedPlayer(
      Player(
        configuration: PlayerConfiguration(
          bufferSize: cachePolicy.bufferSize,
          osc: false,
          logLevel: MPVLogLevel.values[debug.playerLogLevel],
          adBlocker: adBlockerEnabled,
        ),
      ),
    );
    final player = candidate.player;
    if (!canInstall()) {
      await candidate.dispose();
      return null;
    }
    _ownedPlayer = candidate;
    cachePolicy.startWatching();

    try {
      debug.playerLog.clear();
      await debug.setup(
        player,
        isCurrentPlayer: isCurrentPlayer,
        playerDebugMode: playerDebugMode,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      var pp = player.platform as NativePlayer;
      // 装配属性并行下发：open 之前互不依赖的全局选项，Future.wait 把
      // 十几个串行平台通道往返压成一批（典型省 50-150ms）。
      // media-kit 默认启用硬盘作为双重缓存，这可以维持大缓存的前提下
      // 减轻内存压力；demuxer-cache-dir 按平台正确启用双重缓存。
      await Future.wait([
        getPlayerTempPathCached()
            .then((path) => pp.setProperty("demuxer-cache-dir", path)),
        cachePolicy.apply(),
        pp.setProperty("af", "scaletempo2=max-speed=8"),
        _applyAndroidAudioProperties(pp),
        _applyProxyProperty(pp),
        player.setAudioTrack(AudioTrack.auto()),
      ]);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      String? videoRenderer;
      if (Platform.isAndroid) {
        final String androidVideoRenderer =
            GStorage.getSetting(SettingsKeys.androidVideoRenderer);

        if (androidVideoRenderer == 'auto') {
          // Android 14 及以上使用基于 Vulkan 的 MPV GPU-NEXT 视频输出，着色器性能更好
          // GPU-NEXT 需要 Vulkan 1.2 支持
          // 避免 Android 13 及以下设备上部分机型 Vulkan 支持不佳导致的黑屏问题
          final int androidSdkVersion =
              await PlatformEnvironmentService.getAndroidSdkVersion();
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          if (androidSdkVersion >= 34) {
            videoRenderer = 'gpu-next';
          } else {
            videoRenderer = 'gpu';
          }
        } else {
          videoRenderer = androidVideoRenderer;
        }
      }

      if (videoRenderer == 'mediacodec_embed') {
        hAenable = true;
        hardwareDecoder = 'mediacodec';
        superResolutionMode = SuperResolutionMode.off;
      }

      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      final hadVideoController = videoController != null;
      videoController ??= VideoController(
        player,
        configuration: VideoControllerConfiguration(
          vo: videoRenderer,
          enableHardwareAcceleration: hAenable,
          enableAndroidSurfaceProducer: false,
          hwdec: hAenable ? hardwareDecoder : 'no',
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      player.setPlaylistMode(PlaylistMode.none);
      if (!isCurrentPlayer(player)) {
        // 本调用刚创建的 VideoController 随候选一起丢弃，
        // 不给下一次 init 留下死纹理。
        if (!hadVideoController) {
          videoController = null;
        }
        return await _discardIfNotCurrent(candidate);
      }

      player.stream.error.listen((event) {
        if (!isCurrentPlayer(player)) {
          return;
        }
        // 错误时间戳先行更新：isAbnormalEnd 依赖它区分假 EOF。
        _lastStreamErrorAt = DateTime.now();
        if (event.toString().contains('Failed to open') && playerBuffering) {
          // 初始加载失败：本地代理播放时先用原始直链重开一次，
          // 直连也打不开才提示换源。
          // 自愈动作不受「错误提示」开关控制（v1.5.3）：开关只决定
          // toast 的显示——否则关提示的用户坏链既无直连重试也无提示，
          // 只能烧完自动恢复配额后静默卡死。
          if (!_attemptDirectFallback(player)) {
            // 每次读实时值：用户在播放中途开关「错误提示」立即生效。
            if (GStorage.getSetting<bool>(SettingsKeys.showPlayerError)) {
              MiruDialog.showToast(
                  message: '加载失败, 请尝试更换其他视频来源',
                  showActionButton: true);
            }
          }
        } else if (GStorage.getSetting<bool>(SettingsKeys.showPlayerError)) {
          // 瞬时错误：绝大多数会被 ffmpeg 重连自愈，
          // 延迟复检确认真的影响播放才提示。
          _showTransientErrorToast(player, event);
        }
        MiruLogger().e('PlayerController: Player intent error ${videoUrl()}',
            error: event);
        _maybeScheduleAutoRecovery(player);
      });

      // 播放态直通（v1.5.3）：buffering/playing 直接订阅 mpv 流，转圈
      // spinner 随真实状态即时翻转；1Hz 轮询保留给历史持久化等低频
      // 任务。buffer 流同步更新可观察量并驱动缓冲提升（§1.7）。
      // §2.1：订阅随实例注册一次，softStop 不取消（实例常驻）。
      _playbackStateSubscriptions.addAll([
        player.stream.buffering.listen((value) {
          if (!isCurrentPlayer(player)) return;
          if (isBuffering != value) {
            isBuffering = value;
          }
        }),
        player.stream.playing.listen((value) {
          if (!isCurrentPlayer(player)) return;
          if (playing != value) {
            playing = value;
          }
        }),
        player.stream.buffer.listen((value) {
          if (!isCurrentPlayer(player)) return;
          if (buffer != value) {
            buffer = value;
          }
          _maybePromoteBuffering(player, value);
        }),
      ]);

      return player;
    } catch (error, stackTrace) {
      if (identical(_ownedPlayer, candidate)) {
        cachePolicy.stopWatching();
        _ownedPlayer = null;
        videoController = null;
      }
      await candidate.dispose();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 换集软停（§2.1）：player.stop() 不 dispose，Player/VideoController
  /// 与纹理常驻，观察量复位；流订阅保留（实例还活着）。
  /// 真正销毁只在 [stop]（离开视频页）。
  Future<void> softStop() async {
    final player = mediaPlayer;
    if (player == null) {
      return;
    }
    try {
      await player.stop();
    } catch (_) {}
    playing = false;
    loading = true;
    isBuffering = true;
    completed = false;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
  }

  /// 每集打开（§2.1）：只做随集变化的装配——恢复计数/播放头、超分、
  /// HLS 属性、起播期网络参数（§1.7）→ open。
  /// [httpHeaders] 经 Media.httpHeaders 传给 mpv（http-header-fields）。
  Future<Player?> openMedia(
    Player player, {
    required Map<String, String> httpHeaders,
    int offset = 0,
    VideoSourceFormat videoSourceFormat = VideoSourceFormat.auto,
  }) async {
    if (!isCurrentPlayer(player)) {
      return null;
    }
    startOffset = offset;
    // 新一集开始：自动恢复计数与错误时间戳归零。
    _recoveryCount = 0;
    _lastRecoveryAt = null;
    _lastStreamErrorAt = null;
    _lastHttpHeaders = httpHeaders;
    autoPlay = GStorage.getSetting(SettingsKeys.autoPlay);
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultSuperResolutionMode),
    );

    var pp = player.platform as NativePlayer;

    // 超分随集重设（off 分支负责清掉上一集的 shader）
    await setShader(superResolutionMode, player: player);
    if (!isCurrentPlayer(player)) {
      return null;
    }

    // 起播码率判定放宽（v1.5.3 语义保留，随集重设）：
    // 未标注的 .m3u8 master playlist 会回落 mpv 默认 hls-bitrate=max，
    // 弱网下首帧要等好几秒——与 hybrid 解析服务的宽松判定对齐。
    if (_isHlsPlayback(videoSourceFormat, videoUrl())) {
      // 取首个流（站点推荐清晰度）起播最快，中途仍可手动切清晰度。
      await Future.wait([
        pp.setProperty('demuxer-lavf-format', 'hls'),
        pp.setProperty('hls-bitrate', 'no'),
      ]);
      if (!isCurrentPlayer(player)) {
        return null;
      }
    } else {
      // 上一集强制过 hls 时恢复自动探测（空值 = mpv 默认自动识别）
      try {
        await pp.setProperty('demuxer-lavf-format', '');
      } catch (_) {}
    }

    // 网络流稳定性参数（§1.7，「先快出画，稳了再拉大缓冲」）：
    // 每集重设——promote 会把值拉高，换集必须回落到起播值。
    // 1) demuxer-lavf-o：HTTP 持久连接 + 分片级重试（seg_max_retry/
    //    max_reload 是 HLS 丢片自愈的核心）；
    // 2) stream-lavf-o：连接层重连 + 10s 超时（timeout 单位微秒）；
    // 3) 探测降载：probe-info=nostreams + analyzeduration=1s +
    //    probesize=1MB——起播前的流识别时间大幅压缩；
    // 4) 起播阶段小缓冲（cache-secs=10/readahead=3），首帧后由
    //    _maybePromoteBuffering 提升到 120/10；
    // 5) cache-pause-initial=no：缓冲未满也直接出画；
    // 6) video-sync=audio：音频主时钟，减少起播期丢帧重同步。
    if (!isLocalPlayback()) {
      await Future.wait([
        pp.setProperty('demuxer-lavf-o',
            'http_persistent=1,http_multiple=1,http_seekable=0,'
            'seg_max_retry=3,max_reload=5,'
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=3'),
        pp.setProperty('stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=3,'
            'timeout=10000000'),
        pp.setProperty('demuxer-lavf-probe-info', 'nostreams'),
        pp.setProperty('demuxer-lavf-analyzeduration', '1'),
        pp.setProperty('demuxer-lavf-probesize', '1048576'),
        pp.setProperty('network-timeout', '8'),
        pp.setProperty('cache-pause-initial', 'no'),
        pp.setProperty('cache-pause-wait', '0.5'),
        pp.setProperty('cache-secs', _cacheSecsStartup),
        pp.setProperty('demuxer-readahead-secs', _readaheadSecsStartup),
        pp.setProperty('video-sync', 'audio'),
      ]);
      if (!isCurrentPlayer(player)) {
        return null;
      }
    }
    // 换集重置缓冲提升标记（§1.7）：每集都从起播值重新开始爬坡
    _bufferPromoted = false;

    _effectiveUrl = videoUrl();
    await player.open(
      Media(videoUrl(),
          start: Duration(seconds: offset), httpHeaders: httpHeaders),
      play: autoPlay,
    );
    if (!isCurrentPlayer(player)) {
      return null;
    }

    if (cachePolicy.networkForced) {
      MiruDialog.showToast(message: '正在使用移动数据，已临时启用低内存模式以减少缓存');
    }

    return player;
  }

  /// 首集装配入口（PlayerController.init 调用）：ensurePlayer + openMedia。
  /// 返回 null 表示装配被取消（会话过期/页面关闭）。
  Future<Player?> createVideoController(
    Map<String, String> httpHeaders,
    bool adBlockerEnabled, {
    required bool Function() canInstall,
    int offset = 0,
    VideoSourceFormat videoSourceFormat = VideoSourceFormat.auto,
  }) async {
    final player =
        await ensurePlayer(adBlockerEnabled, canInstall: canInstall);
    if (player == null) {
      return null;
    }
    return openMedia(
      player,
      httpHeaders: httpHeaders,
      offset: offset,
      videoSourceFormat: videoSourceFormat,
    );
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    try {
      var pp = currentPlayer.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await pp.waitForVideoControllerInitializationIfAttached;
      if (!identical(mediaPlayer, currentPlayer)) {
        return;
      }
      switch (mode) {
        case SuperResolutionMode.efficiency:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShadersLite,
            ),
          ]);
          break;
        case SuperResolutionMode.quality:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShaders,
            ),
          ]);
          break;
        case SuperResolutionMode.off:
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
          break;
      }
      superResolutionMode = mode;
    } catch (e) {
      MiruLogger().w('PlayerController: failed to set shader', error: e);
    }
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer!.setRate(playerSpeed);
    } catch (e) {
      MiruLogger()
          .e('PlayerController: failed to set playback speed', error: e);
    }
  }

  Future<void> setVolume(double value) async {
    updateVolume(value);
    await syncVolumeToDevice(preciseVolume >= 0 ? preciseVolume : volume);
  }

  @action
  void updateVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = value;
    if (volume.toInt() == value.toInt()) {
      return;
    }
    volume = value;
  }

  /// 外部来源（硬件键、系统面板等）变更音量时同步，并清除手势缓存
  @action
  void applyExternalVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = -1;
    volume = value;
  }

  void invalidatePreciseVolume() {
    preciseVolume = -1;
  }

  Future<void> syncVolumeToDevice([double? value]) async {
    final vol = (value ?? volume).clamp(0.0, 100.0);
    try {
      if (isDesktop()) {
        await mediaPlayer!.setVolume(vol);
      } else {
        await FlutterVolumeController.setVolume(vol / 100);
      }
    } catch (_) {}
  }

  @action
  void syncPlaybackState() {
    final player = mediaPlayer;
    if (player == null) return;

    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      return;
    }
    if (playing != state.playing) {
      playing = state.playing;
    }
    if (isBuffering != state.buffering) {
      isBuffering = state.buffering;
    }
    if (currentPosition != state.position) {
      currentPosition = state.position;
    }
    if (buffer != state.buffer) {
      buffer = state.buffer;
    }
    if (duration != state.duration) {
      duration = state.duration;
    }
    if (completed != state.completed) {
      completed = state.completed;
    }
  }

  Future<void> playOrPause({
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) async {
    if (playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> stop() async {
    cachePolicy.stopWatching();
    final ownedPlayer = _ownedPlayer;
    _ownedPlayer = null;
    videoController = null;
    playing = false;
    loading = true;
    // 先摘掉播放态流订阅再销毁实例，避免 dispose 期间的残余事件。
    for (final subscription in _playbackStateSubscriptions) {
      unawaited(subscription.cancel());
    }
    _playbackStateSubscriptions.clear();
    // media_kit stops playback as part of disposal before releasing native
    // resources. Debug subscriptions can be cancelled concurrently.
    await Future.wait([
      ownedPlayer?.dispose() ?? Future<void>.value(),
      _cancelDebugInfo(),
    ]);
  }

  Future<Uint8List?> screenshot({String format = 'image/jpeg'}) async {
    return await mediaPlayer!.screenshot(format: format);
  }

  Future<Uint8List?> screenshotPng() async {
    final player = mediaPlayer;
    if (player == null) {
      return null;
    }
    return await screenshotService.capturePng(player);
  }
}
