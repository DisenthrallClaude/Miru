import 'dart:async';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/player/player_controller.dart';
import 'package:miru/pages/player/playback_mask_logic.dart';
import 'package:miru/pages/video/video_controller.dart';
import 'package:miru/pages/video/danmaku_send_sheet.dart';
import 'package:miru/pages/video/video_playback_args.dart';
import 'package:miru/pages/history/history_controller.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/video_source/road_health.dart';
import 'package:miru/pages/player/player_item.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/player/pip_utils.dart';
import 'package:miru/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:miru/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/dialog/material_bottom_sheet.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:miru/pages/player/episode_comments_sheet.dart';
import 'package:window_manager/window_manager.dart';
import 'package:miru/bean/widget/embedded_native_control_area.dart';
import 'package:miru/pages/download/download_controller.dart';
import 'package:miru/pages/download/download_episode_sheet.dart';
import 'package:miru/bean/widget/glass_fab.dart';
import 'package:miru/modules/download/download_module.dart';
import 'package:miru/services/player/timed_shutdown_service.dart';
import 'package:miru/utils/device.dart';
import 'package:miru/services/platform/display_mode_service.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.args,
    required this.playerController,
    required this.videoPageController,
    required this.historyController,
    required this.downloadController,
  });

  final VideoPlaybackArgs args;
  final PlayerController playerController;
  final VideoPageController videoPageController;
  final HistoryController historyController;
  final DownloadController downloadController;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage>
    with TickerProviderStateMixin, WindowListener {
  PlayerController get playerController => widget.playerController;
  VideoPageController get videoPageController => widget.videoPageController;
  bool _didInitializePlayback = false;
  bool _isClosing = false;

  /// v1.6.7（P-2）：本页会话内是否真正开播过（首帧已出）。粘性标志：
  /// 置位后换集/换源不再整体卸载 PlayerItem，避免 Video/Texture 销毁
  /// 重建带来的 vo 拆挂与 seek 竞态；仅在页面重建（initState）时归零。
  bool _playerEverStarted = false;
  HistoryController get historyController => widget.historyController;
  DownloadController get downloadController => widget.downloadController;
  late bool playResume;
  bool showDebugLog = false;
  List<String> webviewLogLines = [];
  StreamSubscription<String>? _logSubscription;
  final FocusNode keyboardFocus =
      FocusNode(debugLabel: 'Video player shortcut scope');

  ScrollController scrollController = ScrollController();
  late GridObserverController observerController;
  late AnimationController animation;
  late Animation<Offset> _rightOffsetAnimation;
  late Animation<double> _maskOpacityAnimation;
  late TabController tabController;

  int visibleRoad = 0;
  bool _tabBodyTargetVisible = true;
  int _tabBodyAnimationRun = 0;

  /// 阶段 3 / §3.3：线路下标 → 健康快照（菜单徽标）。
  Map<int, RoadHealth> _roadHealth = {};

  late final bool disableAnimations;

  StreamSubscription<SyncPlayChatMessage>? _syncChatSubscription;

  static const Duration _offlinePlayerInitDelay = Duration(milliseconds: 400);
  static const Duration _sideTabAnimationDuration = Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    videoPageController.applyPlaybackArgs(widget.args);
    windowManager.addListener(this);
    // Window fullscreen can be changed outside this page through system chrome.
    videoPageController.isDesktopFullscreen();
    tabController = TabController(length: 2, vsync: this);
    observerController = GridObserverController(controller: scrollController);
    animation = AnimationController(
      duration: _sideTabAnimationDuration,
      vsync: this,
    );
    _rightOffsetAnimation = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: const Offset(0.0, 0.0),
    ).animate(CurvedAnimation(
      parent: animation,
      curve: Curves.easeOut,
    ));
    _maskOpacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: Curves.easeIn,
    ));

    playResume = GStorage.getSetting(SettingsKeys.playResume);
    disableAnimations =
        GStorage.getSetting(SettingsKeys.playerDisableAnimations);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInitializePlayback) {
      return;
    }
    _didInitializePlayback = true;
    _initializePlayback();
  }

  void _initializePlayback() {
    if (videoPageController.isOfflineMode) {
      _initOfflineMode(playerController);
    } else {
      _initOnlineMode(playerController);
    }

    _syncChatSubscription =
        playerController.syncplay.chatStream.listen((event) {
      final localUsername =
          playerController.syncplay.syncplayController?.username ?? '';
      final String displayText = '${event.username}：${event.message}';

      if (playerController.danmaku.danmakuOn &&
          event.username != localUsername &&
          event.fromRemote) {
        playerController.danmaku.canvasController.addDanmaku(
          DanmakuContentItem(
            displayText,
            color: Colors.orange,
            isColorful: true,
            type: DanmakuItemType.bottom,
            extra: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    });
  }

  void _initOfflineMode(PlayerController playerController) {
    _showTabBodyImmediately(locateEpisode: false);
    final identity = videoPageController.currentHistoryIdentity;
    videoPageController.historyOffset = identity == null
        ? 0
        : videoPageController.getHistoryOffsetFor(identity);
    visibleRoad = videoPageController.selectedEpisode.road;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(_offlinePlayerInitDelay);
      if (!mounted) {
        return;
      }

      await changeEpisode(
        videoPageController.selectedEpisode.episode,
        currentRoad: videoPageController.selectedEpisode.road,
        offset: videoPageController.historyOffset,
      );
    });
  }

  void _initOnlineMode(PlayerController playerController) {
    videoPageController.historyOffset = 0;
    _showTabBodyImmediately(locateEpisode: false);

    var progress = historyController.lastWatching(
        videoPageController.bangumiItem,
        videoPageController.currentPlugin.name);
    if (progress != null) {
      if (videoPageController.roadList.length > progress.road) {
        if (videoPageController.roadList[progress.road].data.length >=
            progress.episode) {
          videoPageController.resetEpisodeState(
            episode: progress.episode,
            road: progress.road,
          );
          if (playResume) {
            videoPageController.historyOffset = progress.progress.inSeconds;
          }
        }
      }
    }
    visibleRoad = videoPageController.selectedEpisode.road;

    // 阶段 3 / §3.3：进页后台摸线路健康（徽标 + 自动选路用）。
    // fire-and-forget，永不阻塞首播。
    _probeRoadHealth();

    _logSubscription = videoPageController.logStream.listen((log) {
      if (mounted) {
        setState(() {
          webviewLogLines.add(log);
          if (webviewLogLines.length > 100) {
            webviewLogLines.removeAt(0);
          }
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      // 阶段 3 / §3.3 自动选路：仅「无播放历史」时依据已持久化的健康分
      // 换线路（有历史尊重历史；无新鲜数据时保持默认——不等待本次
      // 探测，首播永远优先）。
      if (!videoPageController.isOfflineMode &&
          widget.args is OnlineVideoPlaybackArgs &&
          videoPageController.roadList.length > 1) {
        final names = videoPageController.roadList.map((r) => r.name).toList();
        final best = await RoadHealthTracker.instance.bestRoadIndex(
          names,
          videoPageController.currentPlugin.name,
        );
        final current = videoPageController.selectedEpisode.road;
        if (best != current && best < videoPageController.roadList.length) {
          videoPageController.resetEpisodeState(
            episode: videoPageController.selectedEpisode.episode,
            road: best,
          );
          visibleRoad = best;
          MiruLogger().i('VideoPage: auto-selected road $best'
              ' (${names[best]}) by health score');
        }
      }
      changeEpisode(videoPageController.selectedEpisode.episode,
          currentRoad: videoPageController.selectedEpisode.road,
          offset: videoPageController.historyOffset);
    });
  }

  /// 阶段 3 / §3.3：后台探测线路健康，刷新菜单徽标。
  void _probeRoadHealth() {
    if (videoPageController.isOfflineMode ||
        videoPageController.roadList.isEmpty) {
      return;
    }
    final pluginName = videoPageController.currentPlugin.name;
    final roads = videoPageController.roadList
        .map((r) => (r.name, r.data))
        .toList(growable: false);
    unawaited(
      RoadHealthTracker.instance.probeAll(roads, pluginName).then((_) async {
        final fresh = <int, RoadHealth>{};
        for (var i = 0; i < videoPageController.roadList.length; i++) {
          final health = await RoadHealthTracker.instance
              .healthOf(pluginName, videoPageController.roadList[i].name);
          if (health != null) fresh[i] = health;
        }
        if (mounted) {
          setState(() {
            _roadHealth = fresh;
          });
        }
      }).catchError((_) {}),
    );
  }

  @override
  void dispose() {
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    try {
      scrollController.dispose();
    } catch (_) {}
    try {
      animation.dispose();
    } catch (_) {}
    try {
      _syncChatSubscription?.cancel();
    } catch (_) {}
    try {
      _logSubscription?.cancel();
    } catch (_) {}
    // Cancellation and log-stream teardown happen in VideoPageController's
    // own dispose when Modular releases the route scope.
    if (!isDesktop()) {
      try {
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      } catch (_) {}
    }
    DisplayModeService.unlockScreenRotation();
    keyboardFocus.dispose();
    tabController.dispose();
    TimedShutdownService().cancel();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    _hideTabBodyImmediately();
    videoPageController.handleOnEnterFullScreen();
  }

  @override
  void onWindowLeaveFullScreen() {
    videoPageController.handleOnExitFullScreen();
  }

  void showDebugConsole() {
    setState(() {
      showDebugLog = true;
    });
  }

  void hideDebugConsole() {
    setState(() {
      showDebugLog = false;
    });
  }

  void switchDebugConsole() {
    setState(() {
      showDebugLog = !showDebugLog;
    });
  }

  void clearWebviewLog() {
    setState(() {
      webviewLogLines.clear();
    });
  }

  Future<void> changeEpisode(int episode,
      {int currentRoad = 0, int offset = 0}) async {
    if (!mounted) {
      return;
    }
    clearWebviewLog();
    hideDebugConsole();
    await videoPageController.changeEpisode(episode,
        currentRoad: currentRoad,
        offset: offset,
        playerController: playerController);
  }

  void menuJumpToCurrentEpisode() {
    Future.delayed(const Duration(milliseconds: 20), () async {
      if (!mounted) {
        return;
      }
      // 第 1 集应跳到 index 0：原先 episode>1?episode-1:episode 把第 1 集
      // 跳到 index 1（第二格），固定 4 列同行看不出来，列数自适应后会
      // 真实跳偏。
      final selection = videoPageController.selectedEpisode;
      final maxIndex = selection.road >= 0 &&
              selection.road < videoPageController.roadList.length
          ? videoPageController.roadList[selection.road].data.length - 1
          : 0;
      await observerController.jumpTo(
        index: (selection.episode - 1).clamp(0, maxIndex < 0 ? 0 : maxIndex),
      );
    });
  }

  bool get _isSideTabLayout =>
      MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;

  bool get _canAnimateSideTab =>
      mounted && _isSideTabLayout && !disableAnimations;

  void _openTabBodyAnimated() {
    _setTabBodyVisible(true, animated: true);
    menuJumpToCurrentEpisode();
  }

  void _closeTabBodyAnimated() {
    _setTabBodyVisible(false, animated: true);
    keyboardFocus.requestFocus();
  }

  void _toggleTabBodyAnimated() {
    if (_tabBodyTargetVisible) {
      _closeTabBodyAnimated();
    } else {
      _openTabBodyAnimated();
    }
  }

  void _showTabBodyImmediately({bool locateEpisode = true}) {
    _setTabBodyVisible(true, animated: false);
    if (locateEpisode) {
      menuJumpToCurrentEpisode();
    }
  }

  void _hideTabBodyImmediately() {
    _setTabBodyVisible(false, animated: false);
  }

  void _setTabBodyVisible(bool visible, {required bool animated}) {
    _tabBodyTargetVisible = visible;
    final int animationRun = ++_tabBodyAnimationRun;

    if (visible) {
      if (!videoPageController.showTabBody) {
        animation.value = 0.0;
        videoPageController.showTabBody = true;
      }
      if (_canAnimateSideTab && animated) {
        animation.forward(from: animation.value);
      } else {
        animation.value = 1.0;
      }
      return;
    }

    if (!videoPageController.showTabBody) {
      animation.value = 0.0;
      return;
    }

    if (_canAnimateSideTab && animated && animation.value > 0.0) {
      animation.reverse().whenComplete(() {
        if (!mounted || animationRun != _tabBodyAnimationRun) {
          return;
        }
        videoPageController.showTabBody = false;
        animation.value = 0.0;
      });
      return;
    }

    videoPageController.showTabBody = false;
    animation.value = 0.0;
  }

  void _syncTabBodyAnimationAfterLayout() {
    if (!_tabBodyTargetVisible) {
      if (!videoPageController.showTabBody) {
        animation.value = 0.0;
      }
      return;
    }
    if (!videoPageController.showTabBody) {
      animation.value = 0.0;
      return;
    }
    if (!_isSideTabLayout || disableAnimations) {
      animation.value = 1.0;
      return;
    }
    if (animation.value == 0.0 && animation.status != AnimationStatus.reverse) {
      animation.forward();
    }
  }

  void onBackPressed(BuildContext context) async {
    if (MiruDialog.observer.hasMiruDialog) {
      MiruDialog.dismiss();
      return;
    }
    if (videoPageController.isPip && isDesktop()) {
      PipUtils.exitDesktopPIPWindow();
      videoPageController.isPip = false;
      return;
    }
    if (videoPageController.isFullscreen && !isTablet()) {
      menuJumpToCurrentEpisode();
      await DisplayModeService.exitFullScreen();
      _hideTabBodyImmediately();
      videoPageController.isFullscreen = false;
      return;
    }
    if (videoPageController.isFullscreen) {
      await DisplayModeService.exitFullScreen();
      videoPageController.isFullscreen = false;
    }
    if (_isClosing) {
      return;
    }
    _isClosing = true;
    playerController.beginShutdown();
    if (!context.mounted) {
      return;
    }
    context.pop();
  }

  void pauseForTimedShutdown() {
    if (playerController.playback.playing) {
      playerController.pause();
    }
  }

  bool sendDanmaku(String msg) {
    keyboardFocus.requestFocus();
    if (playerController.danmaku.danDanmakus.isEmpty) {
      MiruDialog.showToast(
        message: '当前剧集不支持弹幕发送的说',
      );
      return false;
    }
    if (msg.isEmpty) {
      MiruDialog.showToast(message: '弹幕内容为空');
      return false;
    } else if (msg.length > 100) {
      MiruDialog.showToast(message: '弹幕内容过长');
      return false;
    }

    final destination = playerController.danmaku.danmakuDestination;

    if (destination == DanmakuDestination.chatRoom) {
      if (playerController.syncplay.syncplayRoom.isEmpty) {
        MiruDialog.showToast(message: '你还没有加入一起看，无法发送聊天室弹幕');
        return false;
      }

      final sender =
          playerController.syncplay.syncplayController?.username ?? '我';
      final String displayText = '$sender：$msg';

      playerController.danmaku.canvasController.addDanmaku(
        DanmakuContentItem(
          displayText,
          color: Colors.orange,
          isColorful: true,
          type: DanmakuItemType.bottom,
          extra: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      unawaited(playerController.sendSyncPlayChatMessage(msg));
    } else {
      // The remote danmaku provider does not expose a send API here; render the
      // local echo so the user still sees their message immediately.
      playerController.danmaku.canvasController
          .addDanmaku(DanmakuContentItem(msg, selfSend: true));
    }

    return true;
  }

  /// video_controller 的兑底 catch 会把原始异常拼进「视频解析失败：…」，
  /// DioException 堆栈味内容直接怼给用户与全 app 其余克制文案撕裂。
  /// 视图层先收敛成克制文案（源头文案归 B2 域收敛，这里只做展示兑底）。
  String _friendlyErrorMessage(String raw) {
    if (raw.startsWith('视频解析失败：')) {
      return '视频解析失败，请重试或切换线路';
    }
    return raw;
  }

  Future<void> showMobileDanmakuInput() async {
    final message = await showMobileDanmakuInputSheet(context);

    if (!mounted || message == null) {
      return;
    }
    await showDanmakuDestinationPickerAndSend(message);
  }

  Future<bool> showDanmakuDestinationPickerAndSend(String msg) async {
    if (msg.trim().isEmpty) {
      MiruDialog.showToast(message: '弹幕内容为空');
      return false;
    }

    final DanmakuDestination? result =
        await showAdaptiveBottomSheet<DanmakuDestination>(
      context: context,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MaterialBottomSheetHeader(
                title: '发送弹幕至',
                description: '选择这条弹幕的发送位置',
                onClose: () => Navigator.of(context).pop(),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MaterialBottomSheetGroup(
                  title: '发送位置',
                  children: [
                    ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      leading: const Icon(Icons.groups_rounded),
                      title: const Text('发送到聊天室'),
                      subtitle: const Text('同步观看成员均可看到'),
                      onTap: () => Navigator.of(context)
                          .pop(DanmakuDestination.chatRoom),
                    ),
                    ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      leading: const Icon(Icons.cloud_upload_rounded),
                      title: const Text('发送到远程弹幕库'),
                      subtitle: const Text('作为视频弹幕发送'),
                      onTap: () => Navigator.of(context)
                          .pop(DanmakuDestination.remoteDanmaku),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    if (result == null || !mounted) {
      return false;
    }

    setState(() {});
    playerController.danmaku.danmakuDestination = result;
    return sendDanmaku(msg);
  }

  @override
  Widget build(BuildContext context) {
    final bool isLandscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncTabBodyAnimationAfterLayout();
    });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        onBackPressed(context);
      },
      child: OrientationBuilder(builder: (context, orientation) {
        if (!isDesktop()) {
          if (orientation == Orientation.landscape &&
              !videoPageController.isFullscreen) {
            _hideTabBodyImmediately();
            videoPageController.enterFullScreen();
          } else if (orientation == Orientation.portrait &&
              videoPageController.isFullscreen) {
            videoPageController.exitFullScreen();
            _showTabBodyImmediately();
          }
        }
        return Observer(builder: (context) {
          return Scaffold(
            appBar: null,
            body: SafeArea(
                top: !videoPageController.isFullscreen,
                // set iOS and Android navigation bar to immersive
                bottom: false,
                left: !videoPageController.isFullscreen,
                right: !videoPageController.isFullscreen,
                child: Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    Column(
                      children: [
                        Flexible(
                          flex: isLandscape ? 1 : 0,
                          child: Container(
                            color: Colors.black,
                            height: isLandscape
                                ? MediaQuery.sizeOf(context).height
                                : MediaQuery.sizeOf(context).width * 9 / 16,
                            width: MediaQuery.sizeOf(context).width,
                            child: Focus(
                              focusNode: keyboardFocus,
                              autofocus: true,
                              child: playerBody,
                            ),
                          ),
                        ),
                        if (!isLandscape) Expanded(child: tabBody),
                      ],
                    ),
                    if (isLandscape && videoPageController.showTabBody) ...[
                      if (disableAnimations) ...[
                        sideTabMask,
                        sideTabBody,
                      ] else ...[
                        FadeTransition(
                          opacity: _maskOpacityAnimation,
                          child: sideTabMask,
                        ),
                        SlideTransition(
                          position: _rightOffsetAnimation,
                          child: sideTabBody,
                        ),
                      ],
                    ],
                  ],
                )),
          );
        });
      }),
    );
  }

  Widget get sideTabBody {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height,
      width: (!isDesktop() && !isTablet())
          ? MediaQuery.sizeOf(context).height
          : (MediaQuery.sizeOf(context).width / 3 > 420
              ? 420
              : MediaQuery.sizeOf(context).width / 3),
      child: Container(
        color: Theme.of(context).canvasColor,
        child: GridViewObserver(
          controller: observerController,
          child:
              (isDesktop() || isTablet()) ? tabBody : _mobileLandscapeSidePanel,
        ),
      ),
    );
  }

  /// 横屏手机侧栏：双 Tab（选集/评论）+ 底部发弹幕入口 + 下载 FAB。
  ///
  /// 原先手机横屏展开侧栏只有精简版（线路菜单+选集网格），完整版
  /// tabBody 里的评论 Tab、发弹幕药丸、下载 FAB 全部缺席——看评论/
  /// 缓存必须退出全屏。评论复用现成的 EpisodeCommentsSheet；弹幕入口
  /// 与竖屏共用同一条链路（手机横屏下不适合内嵌输入框，仍走输入 sheet）。
  Widget get _mobileLandscapeSidePanel {
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabBar(
            dividerHeight: 0,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsetsDirectional.only(start: 16, end: 16),
            onTap: (index) {
              if (index == 0) {
                menuJumpToCurrentEpisode();
              }
            },
            tabs: const [
              Tab(text: '选集'),
              Tab(text: '评论'),
            ],
          ),
          Divider(height: 0.2),
          Expanded(
            child: TabBarView(
              children: [
                Stack(
                  children: [
                    Column(
                      children: [
                        menuBar,
                        menuBody,
                      ],
                    ),
                    if (!videoPageController.isOfflineMode) _buildDownloadFab(),
                  ],
                ),
                EpisodeCommentsSheet(
                  episode: videoPageController.commentsEpisode,
                  selection: videoPageController.selectedEpisode,
                  videoPageController: videoPageController,
                ),
              ],
            ),
          ),
          // 侧栏底部固定发弹幕入口：与竖屏「点我发弹幕」同一条链路。
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildDanmakuEntryPill(),
            ),
          ),
        ],
      ),
    );
  }

  Widget get sideTabMask {
    return GestureDetector(
      onTap: _closeTabBodyAnimated,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.black.withValues(alpha: 0.5),
              Colors.transparent,
            ],
          ),
        ),
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }

  Widget get playerBody {
    // v1.6.8（F2/R-2）：遮罩只在「视频尚未真正开始」时显示，且
    // 「真正开始」= 首帧信号（videoParams 宽高就绪）或纯音频延迟兑底
    //（hasAudioOnlyFallback：duration 已知 3s 后仍无首帧才置位）。
    //
    // v1.6.7 曾拿 duration>0 即时兑底，但 HLS VOD 的 duration 在清单
    // 解析即知、远早于首帧——遮罩提前撤下，「出声→首帧」的黑窗（mpv
    // 音频包小先出声、视频首帧要等解码+mediacodec+GPU 上载）整个暴露
    // 给用户：有声 + 纯黑 + 无转圈。另：playerLoading 不再乘
    // playback.loading 因子——装配结束（loading=false）到首帧之间
    // 遮罩保持覆盖（转圈 + 「已解析完成，正在缓冲视频…」文案），
    // 首帧/纯音频判定到达才撤。两信号均为每集 sticky、softStop 复位，
    // 播放中暂停不会误亮遮罩。谓词收敛在 playback_mask_logic.dart
    //（可单测锁定五场景状态机）。
    final playback = playerController.playback;
    final bool playerActuallyStarted = playbackActuallyStarted(
      hasVideoParams: playback.hasVideoParams,
      hasAudioOnlyFallback: playback.hasAudioOnlyFallback,
    );
    if (playerActuallyStarted) {
      // v1.6.7（P-2）：页面会话粘性标志——一旦真正播过，换集/换源的
      // loading 期间不再整体卸载 PlayerItem（Video 卸载会销毁 Texture →
      // widListener 重放 vo=null→vo + seek(position)，吞帧且可能把续播
      // 起点拽回 0）；黑屏观感由上层遮罩负责。
      _playerEverStarted = true;
    }
    // R-2：去掉 playback.loading 因子——装配结束→首帧之间遮罩保持覆盖。
    final bool playerLoading = !playerActuallyStarted;
    return Stack(
      children: [
        Positioned.fill(
          child: Stack(
            children: [
              if (playbackMaskVisible(
                pageLoading: videoPageController.loading,
                actuallyStarted: playerActuallyStarted,
                errorMessage: videoPageController.errorMessage,
              ))
                Container(
                  color: Colors.black,
                  child: Observer(builder: (context) {
                    return Center(
                      child: videoPageController.errorMessage != null
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.error_outline,
                                    color: Theme.of(context).colorScheme.error,
                                    size: 48),
                                const SizedBox(height: 16),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 32),
                                  child: Text(
                                    _friendlyErrorMessage(
                                        videoPageController.errorMessage!),
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 16),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                // 解析失败是本应用最高频失败态（线路挂/防
                                // 盗链），黑屏只有一行字没有任何动作——用户
                                // 得自己去顶栏摸小刷新图标。直接给「重试当
                                // 前集」；横屏侧栏布局下再给「换个线路」。
                                const SizedBox(height: 24),
                                FilledButton.icon(
                                  onPressed: () {
                                    changeEpisode(
                                        videoPageController
                                            .selectedEpisode.episode,
                                        currentRoad: videoPageController
                                            .selectedEpisode.road);
                                  },
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重试'),
                                ),
                                if (videoPageController.roadList.length > 1 &&
                                    MediaQuery.sizeOf(context).width >
                                        MediaQuery.sizeOf(context).height)
                                  TextButton(
                                    onPressed: _toggleTabBodyAnimated,
                                    child: const Text('换个线路'),
                                  ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .tertiaryContainer),
                                const SizedBox(height: 10),
                                // v1.6.4：解析耗时实时可见——转圈不再是
                                // 无限等待的错觉，用户能对照设置里的
                                // 解析超时预算判断当前状态。
                                _ResolveStatusText(
                                  resolving: videoPageController.loading,
                                ),
                              ],
                            ),
                    );
                  }),
                ),
              Visibility(
                visible: (videoPageController.loading || playerLoading) &&
                    showDebugLog,
                child: Container(
                  color: Colors.black,
                  child: Align(
                    alignment: Alignment.center,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: webviewLogLines.length,
                      itemBuilder: (context, index) {
                        return Text(
                          webviewLogLines.isEmpty ? '' : webviewLogLines[index],
                          style: const TextStyle(
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        );
                      },
                    ),
                  ),
                ),
              ),
              Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: EmbeddedNativeControlArea(
                      requireOffset: !videoPageController.isFullscreen,
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back,
                                color: Colors.white),
                            onPressed: () => onBackPressed(context),
                          ),
                          const Expanded(
                              child: dtb.DragToMoveArea(
                                  child: SizedBox(height: 40))),
                          IconButton(
                            icon: const Icon(Icons.refresh_outlined,
                                color: Colors.white),
                            onPressed: () {
                              changeEpisode(
                                  videoPageController.selectedEpisode.episode,
                                  currentRoad:
                                      videoPageController.selectedEpisode.road);
                            },
                          ),
                          Visibility(
                            visible: MediaQuery.sizeOf(context).width >
                                MediaQuery.sizeOf(context).height,
                            child: IconButton(
                              onPressed: () {
                                _toggleTabBodyAnimated();
                              },
                              icon: Icon(
                                _tabBodyTargetVisible
                                    ? Icons.menu_open
                                    : Icons.menu_open_outlined,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                                showDebugLog
                                    ? Icons.bug_report
                                    : Icons.bug_report_outlined,
                                color: Colors.white),
                            onPressed: () {
                              switchDebugConsole();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Positioned.fill(
          // v1.6.7（P-2）+ v1.6.8（F3/R-12）：同遮罩条件的首帧语义 +
          // 页面会话粘性标志——首次真正开播前挂 Container()（实例装配
          // 期），开播后【本页会话内常驻】：换集/换源 loading 期间不再
          // 卸载（Texture 销毁重建会触发 widListener 的 vo 拆挂 + seek
          // 竞态）。唯一豁免：errorMessage 非空——错误是本集终态（mpv
          // 已停/未起、video-params 已清、position=0），卸载 Video 无
          // vo 竞态风险；而 PlayerItem 是本 Stack 最上层的不透明黑底，
          // 不卸载会把错误页/重试按钮/顶栏全部遮死（v1.6.7 回归：
          // 换集失败后黑屏永转圈零入口）。重试（changeEpisode →
          // _beginEpisodeSwitch 清 errorMessage）与正常链路完全一致。
          child: playerItemMounted(
            assemblyLoading: playerController.playback.loading,
            everStarted: _playerEverStarted,
            errorMessage: videoPageController.errorMessage,
          )
              ? PlayerItem(
                  playerController: playerController,
                  videoPageController: videoPageController,
                  toggleMenu: _toggleTabBodyAnimated,
                  showMenuImmediately: _showTabBodyImmediately,
                  hideMenuImmediately: _hideTabBodyImmediately,
                  changeEpisode: changeEpisode,
                  onBackPressed: onBackPressed,
                  keyboardFocus: keyboardFocus,
                  sendDanmaku: sendDanmaku,
                  disableAnimations: disableAnimations,
                  showDanmakuDestinationPickerAndSend:
                      showDanmakuDestinationPickerAndSend,
                  pauseForTimedShutdown: pauseForTimedShutdown,
                )
              : Container(),
        ),
      ],
    );
  }

  Widget get menuBar {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 全角空格伪 padding 换真实 Padding：空格宽度随字号缩放，
          // 放大字体下间距失真。
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text('合集'),
          ),
          Expanded(
            child: Text(
              videoPageController.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 10),
          MenuAnchor(
            consumeOutsideTap: true,
            builder: (_, MenuController controller, __) {
              return SizedBox(
                height: 34,
                child: TextButton(
                  style: ButtonStyle(
                    padding: WidgetStateProperty.all(EdgeInsets.zero),
                  ),
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                  child: Text(
                    visibleRoad >= 0 &&
                            visibleRoad < videoPageController.roadList.length
                        ? '${videoPageController.roadList[visibleRoad].name} '
                        : '播放线路${visibleRoad + 1} ',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              );
            },
            menuChildren: List<MenuItemButton>.generate(
              videoPageController.roadList.length,
              (int i) => MenuItemButton(
                onPressed: () {
                  setState(() {
                    visibleRoad = i;
                  });
                },
                child: Container(
                  height: 48,
                  constraints: BoxConstraints(minWidth: 112),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            videoPageController.roadList[i].name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: i == visibleRoad
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                          ),
                        ),
                        // 阶段 3 / §3.3：线路健康徽标（未知不显示，
                        // 不猜疑未探测的线路）。
                        if (_roadHealth[i] != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _RoadHealthBadge(health: _roadHealth[i]!),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  DownloadEpisode? _getEpisodeFromRecords(
      int episodeNumber, String episodePageUrl) {
    final bangumiId = videoPageController.bangumiItem.id;
    final pluginName = videoPageController.currentPlugin.name;

    for (final record in downloadController.records) {
      if (record.bangumiId == bangumiId && record.pluginName == pluginName) {
        if (episodePageUrl.isNotEmpty) {
          for (final episode in record.episodes.values) {
            if (episode.episodePageUrl == episodePageUrl) {
              return episode;
            }
          }
        }
        return record.episodes[episodeNumber];
      }
    }
    return null;
  }

  Widget _buildDownloadStatusIcon(int episodeNumber, String episodePageUrl) {
    if (videoPageController.isOfflineMode) return const SizedBox.shrink();
    final episode = _getEpisodeFromRecords(episodeNumber, episodePageUrl);
    if (episode == null) return const SizedBox.shrink();
    switch (episode.status) {
      case DownloadStatus.completed:
        return Icon(Icons.offline_pin,
            size: 16, color: Theme.of(context).colorScheme.primary);
      case DownloadStatus.downloading:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            value: episode.progressPercent,
            strokeWidth: 2,
          ),
        );
      case DownloadStatus.failed:
        return Icon(Icons.error_outline,
            size: 16, color: Theme.of(context).colorScheme.error);
      case DownloadStatus.paused:
        return Icon(Icons.pause_circle_outline,
            size: 16, color: Theme.of(context).colorScheme.outline);
      case DownloadStatus.pending:
      case DownloadStatus.resolving:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget get menuBody {
    return Observer(
      builder: (context) {
        var cardList = <Widget>[];
        final scheme = Theme.of(context).colorScheme;
        final selection = videoPageController.selectedEpisode;
        if (visibleRoad >= 0 &&
            visibleRoad < videoPageController.roadList.length) {
          final road = videoPageController.roadList[visibleRoad];
          int count = 1;
          for (var urlItem in road.data) {
            int count0 = count;
            final episodeName = count0 - 1 < road.identifier.length
                ? road.identifier[count0 - 1]
                : '第$count0集';
            // 当前集：底色填充 + 粗体——原先只有文字变色 + 12px 小 gif，
            // 卡片底色与普通集相同，4 列网格里扫一眼找不到「我放到哪了」。
            final bool isCurrent =
                count0 == selection.episode && visibleRoad == selection.road;
            // 「已看」按当前播放位置粗略推断（历史所在集之前的集视为看过；
            // per-episode 精确进度记录属数据层另立项）。
            final bool isWatched = !isCurrent && count0 < selection.episode;
            cardList.add(Container(
              margin: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: isCurrent
                    ? scheme.primaryContainer
                    : scheme.onInverseSurface,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.hardEdge,
                child: InkWell(
                  onTap: () async {
                    final bool isCurrentSelection = count0 ==
                            videoPageController.selectedEpisode.episode &&
                        videoPageController.selectedEpisode.road == visibleRoad;
                    if (isCurrentSelection &&
                        // v1.6.8（F3）：失败终态下当前集卡片 = 重试入口。
                        // 去重只挡「正在播/正在解析的当前集」；解析失败的
                        // 错误页被 PlayerItem 黑底遮住的年代里，这张被去重
                        // 吞掉的卡片曾是唯一无反馈的死入口——显式放行。
                        videoPageController.errorMessage == null) {
                      return;
                    }
                    MiruLogger()
                        .i('VideoPageController: video URL is $urlItem');
                    _closeTabBodyAnimated();
                    changeEpisode(count0, currentRoad: visibleRoad);
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: [
                            if (isCurrent) ...<Widget>[
                              Image.asset(
                                'assets/images/playing.gif',
                                color: scheme.onPrimaryContainer,
                                height: 12,
                              ),
                              const SizedBox(width: 6)
                            ],
                            Expanded(
                              child: Text(
                                episodeName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight:
                                      isCurrent ? FontWeight.w600 : null,
                                  color: isCurrent
                                      ? scheme.onPrimaryContainer
                                      : (isWatched
                                          ? scheme.onSurfaceVariant
                                          : scheme.onSurface),
                                ),
                              ),
                            ),
                            // 已看角标：100+ 集长番选集面板最大的信息缺口。
                            if (isWatched)
                              Icon(Icons.done_all_rounded,
                                  size: 14, color: scheme.outline),
                            _buildDownloadStatusIcon(count0, urlItem),
                            const SizedBox(width: 2),
                          ],
                        ),
                        const SizedBox(height: 3),
                      ],
                    ),
                  ),
                ),
              ),
            ));
            count++;
          }
        }
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 0, right: 8, left: 8),
            child: LayoutBuilder(builder: (context, constraints) {
              // 列宽目标 ~100dp：手机 4 列起步，平板/桌面竖向 tabBody 占满
              // 整屏宽时按宽度自适应加列（上限 8）——固定 4 列会把格子拉成
              // 横跨大半屏的宽条，水波纹跟着横跨大半屏。
              final int columns =
                  (constraints.maxWidth / 100).floor().clamp(4, 8).toInt();
              return GridView.builder(
                scrollDirection: Axis.vertical,
                controller: scrollController,
                // 选集方框调小：高度 70→54，一屏能看到更多集数
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 6,
                  mainAxisExtent: 54,
                ),
                itemCount: cardList.length,
                itemBuilder: (context, index) {
                  return cardList[index];
                },
              );
            }),
          ),
        );
      },
    );
  }

  Widget get tabBody {
    final int episodeNum = videoPageController.commentsEpisode;

    return Container(
      color: Theme.of(context).canvasColor,
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TabBar(
                  controller: tabController,
                  dividerHeight: 0,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelPadding:
                      const EdgeInsetsDirectional.only(start: 30, end: 30),
                  onTap: (index) {
                    if (index == 0) {
                      menuJumpToCurrentEpisode();
                    }
                  },
                  tabs: const [
                    Tab(text: '选集'),
                    Tab(text: '评论'),
                  ],
                ),
                if (MediaQuery.sizeOf(context).width <=
                    MediaQuery.sizeOf(context).height) ...[
                  const Spacer(),
                  _buildDanmakuEntryPill(),
                ],
                const SizedBox(width: 8),
              ],
            ),
            Divider(height: isDesktop() ? 0.5 : 0.2),
            Expanded(
              child: TabBarView(
                controller: tabController,
                children: [
                  Stack(
                    children: [
                      GridViewObserver(
                        controller: observerController,
                        child: Column(
                          children: [
                            menuBar,
                            menuBody,
                          ],
                        ),
                      ),
                      if (!videoPageController.isOfflineMode)
                        _buildDownloadFab(),
                    ],
                  ),
                  EpisodeCommentsSheet(
                    episode: episodeNum,
                    selection: videoPageController.selectedEpisode,
                    videoPageController: videoPageController,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「点我发弹幕」药丸：竖屏 tabBody 头部与横屏侧栏底部共用。
  ///
  /// 触达面积 ≥44dp（原先药丸高度仅文本行高+2，约 24dp，在可滚动的
  /// 选集区旁极易点空）；去掉全角空格伪 padding（空格宽度随字号缩放）。
  Widget _buildDanmakuEntryPill() {
    final bool danmakuOn = playerController.danmaku.danmakuOn;
    final Color color = danmakuOn
        ? Theme.of(context).hintColor
        : Theme.of(context).disabledColor;
    return GestureDetector(
      onTap: () {
        if (danmakuOn && !videoPageController.loading) {
          showMobileDanmakuInput();
        } else if (videoPageController.loading) {
          MiruDialog.showToast(message: '请等待视频加载完成');
        } else {
          MiruDialog.showToast(message: '请先打开弹幕');
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: color, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              danmakuOn ? '发弹幕' : '已关闭弹幕',
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(color: color),
            ),
            if (danmakuOn)
              Icon(
                Icons.send_rounded,
                size: 18,
                color: color,
              ),
          ],
        ),
      ),
    );
  }

  /// 下载 FAB：竖屏 tabBody 与横屏手机侧栏的选集 Tab 共用。
  Widget _buildDownloadFab() {
    return Positioned(
      right: 16,
      bottom: 16,
      child: GlassFab(
        onTap: () {
          showAdaptiveBottomSheet<void>(
            context: context,
            builder: (context) => DownloadEpisodeSheet(
              road: visibleRoad,
              videoPageController: videoPageController,
            ),
          );
        },
        icon: Icons.download_rounded,
        tooltip: '下载',
      ),
    );
  }
}

/// 线路健康徽标（阶段 3 / §3.3）：
/// - 存活：⚡ + 延迟（ms，快线路绿色、慢线路琥珀）；
/// - 死亡：☁ 断连图标（红）。
/// 未知线路不渲染本组件（不猜疑未探测的线路）。
class _RoadHealthBadge extends StatelessWidget {
  const _RoadHealthBadge({required this.health});

  final RoadHealth health;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!health.ok) {
      return Icon(
        Icons.cloud_off_outlined,
        size: 14,
        color: scheme.error,
        semanticLabel: '线路不可用',
      );
    }
    // 800ms 以内算快（秒开目标的一半），超过显示提醒色。
    // 走语义色：硬编码 greenAccent(#69F0AE) 在亮色主题浅底菜单上
    // 对比度仅 ~1.6:1（WCAG 最低 4.5:1），延迟数字基本读不清。
    final fast = health.latencyMs <= 800;
    final color = fast ? scheme.primary : scheme.tertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.bolt_rounded,
          size: 14,
          color: color,
          semanticLabel: '线路健康',
        ),
        Text(
          '${health.latencyMs}ms',
          style: TextStyle(
            fontSize: 11,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// v1.6.4：加载层的真实进度文案。
///
/// * 解析阶段：显示已耗时秒数（每 500ms 刷新），与设置里的
///   解析超时预算形成真实对照——不再是无限转圈的错觉；
/// * 缓冲阶段：解析已完成、mpv 正在拉流，按实际耗时显示。
///
/// 计时从组件挂载起算（挂载即遮罩出现 = 本集解析开始），
/// 换集时遮罩重建，计时自然归零。
class _ResolveStatusText extends StatefulWidget {
  const _ResolveStatusText({required this.resolving});

  /// true = 解析层工作中；false = 已解析、播放器缓冲中。
  final bool resolving;

  @override
  State<_ResolveStatusText> createState() => _ResolveStatusTextState();
}

class _ResolveStatusTextState extends State<_ResolveStatusText> {
  final DateTime _startedAt = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsedSeconds =
        DateTime.now().difference(_startedAt).inMilliseconds / 1000.0;
    final label = widget.resolving
        ? '正在解析视频源… ${elapsedSeconds.toStringAsFixed(1)}s'
        : '已解析完成，正在缓冲视频… ${elapsedSeconds.toStringAsFixed(1)}s';
    return Text(
      label,
      style: const TextStyle(color: Colors.white),
    );
  }
}
