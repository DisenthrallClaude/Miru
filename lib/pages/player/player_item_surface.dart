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
        subtitleViewConfiguration: SubtitleViewConfiguration(
          style: TextStyle(
            color: Colors.pink,
            fontSize: 48.0,
            background: Paint()..color = Colors.transparent,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.bold,
            shadows: const [
              Shadow(
                offset: Offset(1.0, 1.0),
                blurRadius: 3.0,
                color: Color.fromARGB(255, 255, 255, 255),
              ),
              Shadow(
                offset: Offset(-1.0, -1.0),
                blurRadius: 3.0,
                color: Color.fromARGB(125, 255, 255, 255),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          padding: const EdgeInsets.all(24.0),
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
