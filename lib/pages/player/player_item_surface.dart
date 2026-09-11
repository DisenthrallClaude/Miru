import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:miru/pages/player/player_controller.dart';

class PlayerItemSurface extends StatefulWidget {
  const PlayerItemSurface({
    super.key,
    required this.playerController,
  });

  final PlayerController playerController;

  @override
  State<PlayerItemSurface> createState() => _PlayerItemSurfaceState();
}

class _PlayerItemSurfaceState extends State<PlayerItemSurface> {
  /// v1.6.7（P-2）：本 State 存活期内是否渲染过 Video。粘性标志：
  /// 置位后换集/换源的 loading 不再卸载 Video（Texture 销毁重建会
  /// 触发 widListener 的 vo=null→vo 拆挂 + seek(position) 竞态，吞帧
  /// 且可能把续播起点拽回 0）。
  bool _everRendered = false;

  @override
  Widget build(BuildContext context) {
    final playerController = widget.playerController;
    return Observer(builder: (context) {
      // v1.6.7（P-1）：「真正开始」以 mpv 的真实首帧信号为准
      //（videoParams 宽高就绪 / 时长已知），不再信任 playing——
      // media_kit 在 loadlist 命令提交瞬间即强制 playing=true（fork
      // real.dart:221-225），与画面无关。loading 只在视频尚未开始时
      // 挡画面（实例仍在装配）；一旦渲染过即常驻（P-2）。
      final playback = playerController.playback;
      final bool actuallyStarted =
          playback.hasVideoParams || playback.duration > Duration.zero;
      if (actuallyStarted) {
        _everRendered = true;
      }
      final bool notReady = playback.videoController == null ||
          (playback.loading && !_everRendered && !actuallyStarted);
      if (notReady) {
        return Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      final aspectRatioMode = playerController.panel.aspectRatioMode;
      final video = Video(
        controller: playerController.playback.videoController!,
        controls: NoVideoControls,
        pauseUponEnteringBackgroundMode: false,
        fit: aspectRatioMode.fit,
        // v1.6.6：这里曾是 media_kit README 示例的原样默认值（粉色 48px
        // 粗体）——从未被定制。48px 在手机 16:9 播放区（高约 220dp）能占
        // 1/4 高度且遮画面。回落到主流播放器的克制样式：白字、常规偏中等
        // 字重、淡黑软投影当描边；字号后续可接设置项（与弹幕字号同套）。
        subtitleViewConfiguration: SubtitleViewConfiguration(
          style: TextStyle(
            color: Colors.white,
            fontSize: 22.0,
            height: 1.35,
            fontWeight: FontWeight.w500,
            background: Paint()..color = Colors.transparent,
            decoration: TextDecoration.none,
            shadows: const [
              Shadow(
                offset: Offset(0, 1),
                blurRadius: 2.0,
                color: Colors.black87,
              ),
            ],
          ),
          textAlign: TextAlign.center,
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        ),
      );

      final frameAspectRatio = aspectRatioMode.frameAspectRatio;
      if (frameAspectRatio == null) {
        return video;
      }
      return AspectRatio(
        aspectRatio: frameAspectRatio,
        child: video,
      );
    });
  }
}
