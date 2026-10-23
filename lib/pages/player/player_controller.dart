import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/services/player/external_playback_launcher.dart';
import 'package:miru/pages/player/controller/player_danmaku_controller.dart';
import 'package:miru/pages/player/controller/player_debug_controller.dart';
import 'package:miru/pages/player/controller/player_models.dart';
import 'package:miru/pages/player/controller/player_seek_controller.dart';
import 'package:miru/pages/player/controller/player_aspect_ratio.dart';
import 'package:miru/pages/player/controller/player_panel_controller.dart';
import 'package:miru/pages/player/controller/player_playback_controller.dart';
import 'package:miru/pages/player/controller/player_super_resolution.dart';
import 'package:miru/pages/player/controller/sponsor_overlay_skipper.dart';
import 'package:miru/pages/player/controller/midroll_sponsor_masker.dart';
import 'package:miru/services/player/mpv_frame_grabber.dart';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:miru/pages/player/controller/player_syncplay_controller.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/shaders/shader_asset_service.dart';
import 'package:miru/pages/download/download_controller.dart';
import 'package:miru/services/player/audio_controller.dart';
import 'package:miru/utils/async_session.dart';
import 'package:miru/utils/device.dart';

export 'package:miru/pages/player/controller/player_models.dart';

class PlayerController implements Disposable {
  PlayerController(
    this.shaderAssetService,
    DownloadController downloadController,
    this.audioController,
  ) {
    danmaku = PlayerDanmakuController(
      isLocalPlayback: () => isLocalPlayback,
      downloadController: downloadController,
    );
  }

  final ShaderAssetService shaderAssetService;
  final AudioController audioController;
  final AsyncSessionOwner _initializations = AsyncSessionOwner();
  Future<void>? _shutdownFuture;
  final PlayerPanelController panel = PlayerPanelController();
  final PlayerDebugController debug = PlayerDebugController();

  late final PlayerDanmakuController danmaku;

  /// v2 去广告：片头赞助水印跳过进行中（播放页据此保持遮罩）。
  final ValueNotifier<bool> sponsorSkipActive = ValueNotifier<bool>(false);

  /// v1.8.0：正片中途压字广告的遮罩区域（归一化到视频画面 0..1）。
  final ValueNotifier<List<Rect>> sponsorMasks =
      ValueNotifier<List<Rect>>(const []);
  int _sponsorGen = 0;
  late final PlayerPlaybackController playback = PlayerPlaybackController(
    shaderAssetService: shaderAssetService,
    debug: debug,
    videoUrl: () => videoUrl,
    isLocalPlayback: () => isLocalPlayback,
  );
  late final PlayerSyncPlayController syncplay = PlayerSyncPlayController(
    bangumiId: () => bangumiId,
    currentEpisode: () => currentEpisode,
    currentRoad: () => currentRoad,
    playing: () => playback.playing,
    currentPosition: () => playback.currentPosition,
    playerPosition: () => playback.playerPosition,
    duration: () => playback.duration,
    pause: pause,
    play: play,
    seek: seek,
  );
  late final PlayerSeekController seeking = PlayerSeekController(
    playback: playback,
    danmaku: danmaku,
    pause: pause,
    play: play,
    onSeekCompleted: _onSeekCompleted,
  );
  late final ExternalPlaybackLauncher externalPlayback =
      ExternalPlaybackLauncher(
    videoUrl: () => videoUrl,
    referer: () => referer,
  );

  late int bangumiId;
  late int currentEpisode;
  late int currentDanmakuEpisodeNumber;
  late int currentRoad;
  late String referer;
  String? coverUrl;
  String videoUrl = '';
  bool isLocalPlayback = false;
  Timer? hideVolumeUITimer;
  Timer? _volumeGestureSyncTimer;
  double? _pendingGestureVolume;

  bool muted = false;
  double _preMuteVolume = 100;

  Future<void> toggleMute() async {
    if (!muted && playback.volume > 0) {
      _preMuteVolume = playback.volume;
      muted = true;
      _persistMuteState();
      await setVolume(0);
    } else {
      muted = false;
      _persistMuteState();
      await setVolume(_preMuteVolume > 0 ? _preMuteVolume : 100);
    }
  }

  void _persistMuteState() {
    if (!isDesktop()) {
      return;
    }
    unawaited(GStorage.putSetting<bool>(SettingsKeys.playerMuted, muted));
  }

  /// 在音量被主动调高（手势 / 按键 / 滚轮）时退出静音状态。
  void _clearMuteIfNeeded(double value) {
    if (muted && value > 0) {
      muted = false;
      _persistMuteState();
    }
  }

  void setVolumeDuringGesture(double value) {
    _pendingGestureVolume = value.clamp(0.0, 100.0);
    playback.updateVolume(_pendingGestureVolume!);
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = Timer(const Duration(milliseconds: 80), () {
      final vol = _pendingGestureVolume;
      if (vol == null) {
        return;
      }
      unawaited(playback.syncVolumeToDevice(vol));
    });
  }

  Future<void> finishVolumeGesture() async {
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = null;
    final vol = _pendingGestureVolume;
    _pendingGestureVolume = null;
    if (vol != null) {
      playback.volume = vol;
    }
    playback.invalidatePreciseVolume();
    await playback.syncVolumeToDevice(vol);
    final resolved = vol ?? playback.volume;
    _clearMuteIfNeeded(resolved);
    _persistDesktopVolume(resolved);
  }

  void _persistDesktopVolume(double value) {
    if (!isDesktop()) {
      return;
    }
    if (muted) {
      return;
    }
    final clamped = value.clamp(0.0, 100.0);
    final stored = GStorage.getSetting(SettingsKeys.defaultVolume);
    if (stored.round() == clamped.round()) {
      return;
    }
    unawaited(GStorage.putSetting<double>(SettingsKeys.defaultVolume, clamped));
  }

  Future<bool> init(PlaybackInitParams params) async {
    if (_initializations.isClosed) {
      return false;
    }
    final initialization = _initializations.begin();

    videoUrl = params.videoUrl;
    isLocalPlayback = params.isLocalPlayback;
    bangumiId = params.bangumiId;
    currentEpisode = params.episode;
    currentDanmakuEpisodeNumber = params.danmakuEpisodeNumber;
    currentRoad = params.currentRoad;
    referer = params.referer;

    MiruLogger().i(
        'PlayerController: ${params.isLocalPlayback ? "local" : "online"} playback, url: ${params.videoUrl}');

    playback.resetForInit();
    // v2 去广告：换集即作废上一集的水印检测流程。
    _sponsorGen++;
    sponsorSkipActive.value = false;
    sponsorMasks.value = const [];
    final int startOffsetSeconds = params.offset;
    playback.onFirstFrameInternal = () {
      _maybeRunSponsorSkip(startOffsetSeconds);
      _maybeRunMidrollMasker();
    };
    // 秒开链路：本地代理打开失败时用原始直链原地重开。
    // 必须在 resetForInit 之后设置——后者会清空兜底地址，先设后清
    // 会让直连兜底永远拿不到地址（v1.5.3 修复装配顺序缺陷）。
    playback.setDirectFallbackUrl(params.directVideoUrl);
    debug.playerLogLevel = GStorage.getSetting(SettingsKeys.playerLogLevel);
    playback.playerSpeed = GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
    panel.aspectRatioMode = PlayerAspectRatio.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultAspectRatioType),
    );

    playback.buttonSkipTime = GStorage.getSetting(SettingsKeys.buttonSkipTime);
    playback.arrowKeySkipTime =
        GStorage.getSetting(SettingsKeys.arrowKeySkipTime);
    // §2.1：播放内核单例常驻——换集只软停（实例/纹理/订阅保留），
    // 全量销毁只在离开视频页（beginShutdown）。无实例时零开销。
    // v1.7.0（P0-2）：改用 awaitPendingSoftStop——changeEpisode 入口
    // 已 unawaited(softStop()) 发起软停，这里再发起一次会造成双发
    // 竞态（缓存命中时第二次 softStop+openMedia 先完成，第一次的
    // 尾部复位落在 open 之后：hasVideoParams 被清、遮罩永转圈）。
    try {
      await playback.awaitPendingSoftStop();
    } catch (_) {}
    if (initialization.isStale) {
      return false;
    }

    final Player? player;
    try {
      player = await playback.createVideoController(
        params.httpHeaders,
        params.adBlockerEnabled,
        canInstall: () => initialization.isActive,
        offset: params.offset,
        videoSourceFormat: params.videoSourceFormat,
      );
    } catch (e) {
      if (initialization.isStale) {
        return false;
      }
      playback.loading = false;
      MiruLogger()
          .e('PlayerController: failed to initialize video', error: e);
      return false;
    }
    if (player == null || !_ownsInitialization(initialization, player)) {
      return false;
    }

    // v1.6.7（P-1 勘误）：open 返回 ≠ 画面已就绪——media_kit 的 open()
    // 只是刚把 loadlist 命令提交给 mpv（并立刻强制 playing=true，fork
    // real.dart:221-225），纹理/首帧远未就绪。「画面是否已出」由
    // playback.hasVideoParams（video-params 事件宽高就绪）判定；纯音频
    // 流由 duration 已知 3s 后的 hasAudioOnlyFallback 兜底（v1.6.8 F2），
    // 播放页遮罩据此撤除。loading 在装配完成时翻转，仅表示「装配结束」，
    // 不再承担「画面已出」语义。
    // 后续音量/速度装配是非致命增强：任何平台通道失败只记日志，
    // 绝不能 (a) 向上抛异常（调用方会把 init 异常误判为「解析失败」
    // 触发换源循环）；(b) 阻塞 loading 翻转。
    MiruLogger().i('PlayerController: video initialized');
    playback.loading = false;
    try {
      await _installVolumeAndSpeed(player, initialization);
    } catch (e, stackTrace) {
      MiruLogger().w(
        'PlayerController: post-open volume/speed assembly failed (non-fatal)',
        error: e,
        stackTrace: stackTrace,
      );
    }

    coverUrl = params.coverUrl;

    if (syncplay.syncplayController?.isConnected ?? false) {
      if (syncplay.syncplayController!.currentFileName !=
          "$bangumiId[$currentEpisode]") {
        setSyncPlayPlayingBangumi(
            forceSyncPlaying: true, forceSyncPosition: 0.0);
      }
    }
    return true;
  }

  /// v2 去广告：从头开播时检测压制进画面的片头赞助水印并跳过。
  /// 详见 [SponsorOverlaySkipper]。任何失败只记日志，不影响播放。
  void _maybeRunSponsorSkip(int startOffsetSeconds) {
    // 「可观看」信号（CI 以此为 t0 截取 t3/t10，验证开头不是广告）。
    void ready(String why) => MiruLogger().i('MIRU_AUTOTEST ready $why');
    if (isLocalPlayback || startOffsetSeconds > 3) return ready('resume');
    if (!GStorage.getSetting(SettingsKeys.skipSponsorOverlay)) {
      return ready('disabled');
    }
    final player = playback.mediaPlayer;
    if (player == null) return ready('no-player');
    final gen = ++_sponsorGen;
    final url = videoUrl;
    bool stale() =>
        gen != _sponsorGen || videoUrl != url || playback.mediaPlayer != player;
    final host = SponsorSkipHost(
      probe: () async {
        // v1.8.0：改用 MpvFrameGrabber（screenshot-raw window）——
        // safeScreenshot 走 video 模式，mediacodec 硬解下恒为 null。
        final f = await MpvFrameGrabber.grab(player);
        if (f == null) return null;
        return SponsorOverlayDetector.analyze(f.bytes,
            width: f.width, height: f.height, stride: f.stride);
      },
      seek: (d) => seek(d, enableSync: false),
      position: () => player.state.position,
      setMuted: (m) async {
        try {
          await (player.platform as NativePlayer)
              .setProperty('mute', m ? 'yes' : 'no');
        } catch (_) {}
      },
      isStale: stale,
    );
    unawaited(SponsorOverlaySkipper.run(host, onActive: (active) {
      if (gen == _sponsorGen) sponsorSkipActive.value = active;
    }).then((outcome) {
      MiruLogger().i('MIRU_AD sponsor outcome=$outcome');
      ready(outcome.kind);
    }).catchError((Object e) {
      if (gen == _sponsorGen) sponsorSkipActive.value = false;
      MiruLogger().w('MIRU_AD sponsor skip failed', error: e);
      ready('error');
    }));
  }

  /// v1.8.0：正片中途压字广告（如 fcdm「582316.com」）检测到才遮、只遮那块。
  /// 详见 [MidrollSponsorMasker]。任何失败只记日志，不影响播放。
  void _maybeRunMidrollMasker() {
    if (isLocalPlayback) return;
    if (!GStorage.getSetting(SettingsKeys.maskMidrollSponsor)) return;
    final player = playback.mediaPlayer;
    if (player == null) return;
    final gen = _sponsorGen;
    final url = videoUrl;
    bool stale() =>
        gen != _sponsorGen || videoUrl != url || playback.mediaPlayer != player;
    final host = MidrollMaskHost(
      grab: () async {
        final f = await MpvFrameGrabber.grab(player);
        if (f == null) return null;
        return MidrollSponsorDetector.analyzeAll(f.bytes,
            width: f.width, height: f.height, stride: f.stride);
      },
      isPlaying: () => player.state.playing,
      isPaused: () => sponsorSkipActive.value,
      isStale: stale,
      onMasks: (masks) {
        if (gen == _sponsorGen) sponsorMasks.value = masks;
      },
    );
    unawaited(MidrollSponsorMasker.run(host).catchError((Object e) {
      MiruLogger().w('MIRU_AD midroll mask failed', error: e);
    }));
  }

  bool _ownsInitialization(AsyncSession initialization, Player player) {
    return initialization.isActive && playback.isCurrentPlayer(player);
  }

  /// v1.7.0（P1-4）：音量监听/系统 UI 隐藏的会话级 once 门——旧实现
  /// 每集 init 都执行一次 addListener（叠加注册）+ updateShowSystemUI。
  bool _volumeListenerInstalled = false;

  /// v1.6.4：open 之后的音量/播放速度装配（从 init 主流程拆出）。
  ///
  /// 全段被 init 的 try-catch 隔离——平台通道（音量服务）任何异常都
  /// 不影响 init 的成功结论；会话失效（换集抢先）则静默返回。
  Future<void> _installVolumeAndSpeed(
    Player player,
    AsyncSession initialization,
  ) async {
    if (isDesktop()) {
      final freshStart = playback.volume == -1;
      if (freshStart) {
        muted = GStorage.getSetting(SettingsKeys.playerMuted);
        final remembered = GStorage.getSetting(SettingsKeys.defaultVolume);
        _preMuteVolume = remembered > 0 ? remembered : 100;
        playback.volume = muted ? 0 : remembered;
      }
      await setVolume(playback.volume);
    } else {
      final initialVolume = await FlutterVolumeController.getVolume();
      playback.volume = (initialVolume ?? 0.0) * 100;
      if (!_ownsInitialization(initialization, player)) {
        return;
      }
      // v1.7.0（P1-4）：系统音量 UI 隐藏 + 监听注册只在播放器生命周期
      // 内执行一次（解除时恢复）。旧实现每集重复：addListener 叠加
      // 注册、updateShowSystemUI 每集白发一次。
      if (!_volumeListenerInstalled) {
        _volumeListenerInstalled = true;
        await FlutterVolumeController.updateShowSystemUI(false);
        if (!_ownsInitialization(initialization, player)) {
          await FlutterVolumeController.updateShowSystemUI(true);
          return;
        }
        FlutterVolumeController.addListener((volume) {
          // v1.7.0（P1-4）：监听器不再捕获某一集的 initialization——
          // 旧回调在第二集起 _ownsInitialization 恒 false，外部音量
          // 变化（硬件键/系统面板）全部失明。liveness 以播放内核
          // 是否在位为准。
          if (playback.mediaPlayer == null) {
            return;
          }
          if (panel.volumeSeeking) {
            return;
          }
          playback.applyExternalVolume(volume * 100);
          if (!Platform.isAndroid && !panel.volumeSeeking) {
            panel.showVolume = true;
            hideVolumeUITimer?.cancel();
            hideVolumeUITimer = Timer(const Duration(seconds: 1), () {
              panel.showVolume = false;
              hideVolumeUITimer = null;
            });
          }
        }, category: AudioSessionCategory.playback, emitOnStart: false);
      }
    }
    if (!_ownsInitialization(initialization, player)) {
      return;
    }
    try {
      await setPlaybackSpeed(playback.playerSpeed);
    } catch (e) {
      MiruLogger()
          .w('PlayerController: setPlaybackSpeed failed (non-fatal)', error: e);
    }
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    await playback.setShader(
      mode,
      player: player,
    );
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    await playback.setPlaybackSpeed(playerSpeed);
    try {
      updateDanmakuSpeed();
    } catch (_) {}
  }

  void updateDanmakuSpeed() {
    danmaku.updateDanmakuSpeed(playback.playerSpeed);
  }

  Future<void> setVolume(double value) async {
    await playback.setVolume(value);
    _clearMuteIfNeeded(value);
    _persistDesktopVolume(value);
  }

  void syncPlaybackState() {
    playback.syncPlaybackState();
  }

  Future<void> playOrPause() async {
    await playback.playOrPause(pause: pause, play: play);
  }

  Future<void> seek(Duration duration, {bool enableSync = true}) =>
      seeking.seekTo(duration, enableSync: enableSync);

  Future<void> seekBy(Duration offset, {bool enableSync = true}) =>
      seeking.seekBy(offset, enableSync: enableSync);

  Future<void> _onSeekCompleted(bool enableSync) async {
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync(doSeek: true);
      }
    }
  }

  Future<void> pause({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    danmaku.canvasController.pause();
    // v1.6.9（P1-2）：用户主动暂停——清空假 EOF 判定的错误时间戳，
    // 后台挂起期的瞬时错误不再把暂停中的 completed 误判为假 EOF
    // 触发自作主张的重开（把用户暂停变成继续播放）。
    playback.clearStreamErrorMarker();
    try {
      await player.pause();
    } catch (_) {
      return;
    }
    playback.playing = false;
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync();
      }
    }
  }

  Future<void> play({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    danmaku.canvasController.resume();
    try {
      await player.play();
    } catch (_) {
      return;
    }
    playback.playing = true;
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync();
      }
    }
  }

  @override
  void dispose() {
    beginShutdown();
  }

  /// Starts the idempotent player shutdown without blocking route navigation.
  ///
  /// Native media and audio-session cleanup may finish after the route is
  /// removed. Immediate ownership detachment happens synchronously before this
  /// method returns.
  void beginShutdown() {
    _initializations.close();
    if (_shutdownFuture != null) {
      return;
    }
    final shutdown = _shutdownResources();
    _shutdownFuture = shutdown;
    unawaited(
      shutdown.catchError((Object error, StackTrace stackTrace) {
        MiruLogger().e(
          'PlayerController: failed to dispose asynchronously',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _shutdownResources() async {
    await Future.wait([
      _releasePlaybackResources(),
      syncplay.dispose(),
    ]);
  }

  Future<void> _releasePlaybackResources() async {
    hideVolumeUITimer?.cancel();
    _volumeGestureSyncTimer?.cancel();
    FlutterVolumeController.removeListener();
    await Future.wait([
      audioController.deactivate(),
      playback.stop(),
      _restoreSystemVolumeUi(),
    ]);
  }

  Future<void> _restoreSystemVolumeUi() async {
    try {
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (error, stackTrace) {
      MiruLogger().w(
        'PlayerController: failed to restore the system volume UI',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> stop() async {
    _initializations.cancel();
    await _releasePlaybackResources();
  }

  /// 换集软停（§2.1）：取消在途初始化会话 + 复位播放内核（不销毁
  /// Player/VideoController/纹理）。旧实例继续常驻，新集 init 时
  /// ensurePlayer 幂等复用，换集不再黑屏重建。
  Future<void> softStop() async {
    _initializations.cancel();
    await playback.softStop();
  }

  Future<Uint8List?> screenshot({String format = 'image/jpeg'}) async {
    return await playback.screenshot(format: format);
  }

  Future<Uint8List?> screenshotPng() async {
    return await playback.screenshotPng();
  }

  void setButtonForwardTime(int time) {
    playback.buttonSkipTime = time;
    GStorage.putSetting(SettingsKeys.buttonSkipTime, time);
  }

  void setArrowKeyForwardTime(int time) {
    playback.arrowKeySkipTime = time;
    GStorage.putSetting(SettingsKeys.arrowKeySkipTime, time);
  }

  Future<void> launchExternalPlayer() async {
    await externalPlayback.launch();
  }

  Future<void> createSyncPlayRoom(
      String room,
      String username,
      Future<void> Function(int episode, {int currentRoad, int offset})
          changeEpisode) async {
    await syncplay.createRoom(
      room,
      username,
      changeEpisode,
    );
  }

  void setSyncPlayCurrentPosition(
      {bool? forceSyncPlaying, double? forceSyncPosition}) {
    syncplay.setCurrentPosition(
      forceSyncPlaying: forceSyncPlaying,
      forceSyncPosition: forceSyncPosition,
    );
  }

  Future<void> setSyncPlayPlayingBangumi(
      {bool? forceSyncPlaying, double? forceSyncPosition}) async {
    await syncplay.setPlayingBangumi(
      forceSyncPlaying: forceSyncPlaying,
      forceSyncPosition: forceSyncPosition,
    );
  }

  Future<void> requestSyncPlaySync({bool? doSeek}) async {
    await syncplay.requestSync(doSeek: doSeek);
  }

  Future<void> sendSyncPlayChatMessage(String message) async {
    await syncplay.sendChatMessage(message);
  }

  Future<void> exitSyncPlayRoom() async {
    await syncplay.exitRoom();
  }
}
