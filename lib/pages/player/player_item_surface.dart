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
  @override
  Widget build(BuildContext context) {
    final playerController = widget.playerController;
    return Observer(builder: (context) {
      // v1.6.4：mpv 已实际开始（playing/有时长）时必须挂载 Video——
      // 此前 loading=true 期间整个 Video widget 被黑色转圈容器顶替，
      // mpv 侧已在解码出帧却无处渲染，用户「有声音没画面」。
      // loading 只在视频尚未开始时挡画面（实例仍在装配）。
      final playback = playerController.playback;
      final bool actuallyStarted =
          playback.playing || playback.duration > Duration.zero;
      final bool notReady = playback.videoController == null ||
          (playback.loading && !actuallyStarted);
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
