import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show Image, ImmutableBuffer, ImageDescriptor;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'liquid_glass_controller.dart';
import 'liquid_glass_copy_widgets.dart';
import 'liquid_glass_painters.dart';
import 'liquid_glass_shaders.dart';
import 'liquid_glass_theme.dart';

/// 液态玻璃欢迎屏 —— 复刻 Appllama/liquid-glass-screens 的
/// LiquidGlassScreen（Sky/Astro 两主题合一，按昼夜选择）。
///
/// 一个手势擦洗整页：巨大的玻璃穹顶坐在底缘；上滑把它推向屏中，
/// 一路缩小成 + 按钮；落定后贴纸从按钮的玻璃里升起结成羽流，
/// 文案与 CTA 淡入；下拉则重新放大并收回羽流
/// （Sky 坠落淡出 / Astro 星尘漩涡入芯）。
class LiquidGlassWelcome extends StatefulWidget {
  const LiquidGlassWelcome({
    super.key,
    required this.theme,
    required this.onEnter,
    required this.onEnterViaGithub,
  });

  final LiquidGlassTheme theme;

  /// 主 CTA「直接进入」。
  final VoidCallback onEnter;

  /// 次入口「通过 GitHub 进入」。
  final VoidCallback onEnterViaGithub;

  @override
  State<LiquidGlassWelcome> createState() => _LiquidGlassWelcomeState();
}

class _LiquidGlassWelcomeState extends State<LiquidGlassWelcome>
    with SingleTickerProviderStateMixin {
  LiquidGlassController? _controller;
  late final Ticker _ticker;

  List<ui.Image?> _stickers = const [];
  ui.Image? _scene;
  bool _shadersReady = false;

  // Sky 视频背景。
  Player? _player;
  VideoController? _videoController;
  bool _videoReady = false;

  double _sx = 1;
  double _sy = 1;
  Size _size = Size.zero;

  LiquidGlassTheme get theme => widget.theme;

  LiquidGlassController get controller => _controller!;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();
    unawaited(_prepare());
  }

  void _onTick(Duration elapsed) {
    _controller?.tick(elapsed);
  }

  Future<void> _prepare() async {
    final ready = await LiquidGlassShaders.preload();
    if (mounted) {
      setState(() => _shadersReady = ready);
    }
    await _loadStickers();
    if (theme.videoAsset != null) {
      await _initVideo();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mq = MediaQuery.of(context);
    if (_size == mq.size) return;
    _size = mq.size;
    _sx = _size.width / 402;
    _sy = _size.height / 874;
    final old = _controller;
    _controller = LiquidGlassController(
      theme: theme,
      width: _size.width,
      height: _size.height,
      reduceMotion: mq.disableAnimations,
    );
    old?.dispose();
    if (theme.videoAsset == null && _scene == null) {
      unawaited(_captureScene());
    }
  }

  Future<void> _loadStickers() async {
    final images = <ui.Image?>[];
    for (final path in theme.stickers) {
      try {
        final data = await rootBundle.load(path);
        final buffer =
            await ui.ImmutableBuffer.fromUint8List(data.buffer.asUint8List());
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        final codec = await descriptor.instantiateCodec();
        final frame = await codec.getNextFrame();
        images.add(frame.image);
      } catch (_) {
        images.add(null);
      }
    }
    if (mounted) {
      setState(() => _stickers = images);
    }
  }

  /// Sky：把 asset 视频拷到应用目录后以文件播放
  /// （与原项目同理：asset 通道对 AVPlayer 的 byte-range 不可靠）。
  Future<void> _initVideo() async {
    try {
      final player = Player();
      final videoController = VideoController(player);
      _player = player;
      _videoController = videoController;

      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/liquid_glass_sky.mp4');
      if (!await file.exists()) {
        final data = await rootBundle.load(theme.videoAsset!);
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }

      await player.open(Media(file.path));
      unawaited(player.setPlaylistMode(PlaylistMode.loop));
      unawaited(player.setVolume(0));

      // Video widget fill 透明：首帧未到时海报从其下透出。
      if (mounted) {
        setState(() => _videoReady = true);
      }
    } catch (_) {
      // 视频失败：海报帧兜底。
    }
  }

  /// Astro：捕获静态星空为透镜场景贴图。
  Future<void> _captureScene() async {
    if (_size == Size.zero) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final scene = await LiquidGlassShaders.captureCoverScene(
      asset: theme.refractionAsset,
      widthLogical: _size.width,
      heightLogical: _size.height,
      dpr: dpr,
    );
    if (mounted) {
      setState(() => _scene = scene);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _controller?.dispose();
    _player?.dispose();
    super.dispose();
  }

  // ── 手势转发 ──────────────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d) {
    _panTotal = Offset.zero;
    controller.onPanBegin(d.globalPosition.dx, d.globalPosition.dy);
    controller.onPanStart();
  }

  Offset _panTotal = Offset.zero;
  DateTime _lastPanTime = DateTime.now();
  Offset _lastPanVelocity = Offset.zero;

  void _onPanUpdate(DragUpdateDetails d) {
    _panTotal += d.delta;
    final now = DateTime.now();
    final dtMs = now.difference(_lastPanTime).inMilliseconds;
    if (dtMs > 4) {
      _lastPanVelocity = Offset(
        d.delta.dx / (dtMs / 1000),
        d.delta.dy / (dtMs / 1000),
      );
      _lastPanTime = now;
    }
    controller.onPanUpdate(
      x: d.globalPosition.dx,
      y: d.globalPosition.dy,
      translationX: _panTotal.dx,
      translationY: _panTotal.dy,
      velocityX: _lastPanVelocity.dx,
      velocityY: _lastPanVelocity.dy,
    );
  }

  void _onPanEnd(DragEndDetails d) {
    controller.onPanEnd(
      d.velocity.pixelsPerSecond.dx,
      d.velocity.pixelsPerSecond.dy,
    );
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // didChangeDependencies 已保证 controller 就绪。
    if (_controller == null) {
      return Scaffold(
        backgroundColor: theme.pageColor,
        body: const SizedBox.expand(),
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          theme.night ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: theme.pageColor,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: () => controller.onPanFinalize(),
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildBackdrop(),
                if (theme.videoAsset != null)
                  _buildSkyLens()
                else
                  _buildAstroLens(),
                AnimatedBuilder(
                  animation: controller,
                  builder: (_, __) => CustomPaint(
                    painter: StickerFieldPainter(
                      controller: controller,
                      theme: theme,
                      images: _stickers,
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: controller,
                  builder: (_, __) => CustomPaint(
                    painter: GlassSpherePainter(
                      controller: controller,
                      theme: theme,
                      dpr: MediaQuery.devicePixelRatioOf(context),
                    ),
                  ),
                ),
                _buildPlus(),
                _buildGateCopy(),
                _buildOpenCopy(),
                _buildPill(),
                _buildGithubEntry(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 背景层 ────────────────────────────────────────────────────────────────

  Widget _buildBackdrop() {
    if (theme.videoAsset != null) {
      // Sky：视频（cover）+ 未就绪时的海报帧。
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            theme.refractionAsset,
            fit: BoxFit.cover,
          ),
          if (_videoReady && _videoController != null)
            Video(
              controller: _videoController!,
              fit: BoxFit.cover,
              fill: const Color(0x00000000),
              controls: NoVideoControls,
              pauseUponEnteringBackgroundMode: false,
            ),
        ],
      );
    }
    // Astro：星星层 + 地平光晕（随球上升散去；物质量再点亮）。
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(theme.refractionAsset, fit: BoxFit.cover),
        AnimatedBuilder(
          animation: controller,
          builder: (_, __) => Opacity(
            opacity: controller.glowAlpha,
            child: Image.asset(
              theme.glowAsset!,
              fit: BoxFit.cover,
            ),
          ),
        ),
        AnimatedBuilder(
          animation: controller,
          builder: (_, __) => Opacity(
            opacity: controller.feedAlpha,
            child: Image.asset(
              theme.glowAsset!,
              fit: BoxFit.cover,
            ),
          ),
        ),
      ],
    );
  }

  /// Sky 的透镜：视频无法采样进 shader，用 clip + 放大近似
  /// （中心放大、随半径变化、slosh 拖影；穹顶态色散 0.05 不可见，省略）。
  Widget _buildSkyLens() {
    final video = _videoController;
    if (video == null || !_videoReady) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final R = controller.radius;
        if (R < 4) return const SizedBox.shrink();
        final amount = _lerpClamped(R, controller.r1, controller.r0, 0.62, 0.42);
        final scale = 1 / (1 - amount * 0.55);
        final cx = controller.orbX;
        final cy = controller.cy;
        final alignment = Alignment(
          (cx / _size.width) * 2 - 1,
          (cy / _size.height) * 2 - 1,
        );
        final slosh = Offset(
          controller.sloshX * R * 0.08,
          controller.sloshY * R * 0.08,
        );
        return Positioned.fill(
          child: IgnorePointer(
            child: ClipOval(
              clipper: _OrbClipper(Offset(cx, cy), R),
              child: Transform.translate(
                offset: slosh,
                child: Transform.scale(
                  scale: scale,
                  alignment: alignment,
                  child: Video(
                    controller: video,
                    fit: BoxFit.cover,
                    fill: const Color(0x00000000),
                    controls: NoVideoControls,
                    pauseUponEnteringBackgroundMode: false,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Astro 的透镜：静态星空已捕获为贴图，shader 做真实折射。
  Widget _buildAstroLens() {
    if (_scene == null || !_shadersReady) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => CustomPaint(
        painter: LensPainter(
          controller: controller,
          theme: theme,
          scene: _scene,
          dpr: MediaQuery.devicePixelRatioOf(context),
        ),
      ),
    );
  }

  // ── 前景元素 ──────────────────────────────────────────────────────────────

  Widget _buildPlus() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final R = controller.radius;
        final opacity =
            _lerpClamped(R, controller.r1 * 1.2, controller.r1 * 1.7, 1, 0);
        if (opacity <= 0) return const SizedBox.shrink();
        return Positioned(
          left: controller.orbX - 30,
          top: controller.cy - 33,
          width: 60,
          height: 60,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Center(
                child: Text(
                  '+',
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w400,
                    color: theme.plus,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGateCopy() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final w = _size.width;
        final h = _size.height;
        final sx = _sx;
        final wordmarkSize = 230 * sx;
        return Stack(
          children: [
            // wordmark。
            Positioned(
              top: h * 0.4368 - 115 * sx,
              left: (w - wordmarkSize) / 2,
              width: wordmarkSize,
              height: wordmarkSize,
              child: SoftCopyBlock(
                fade: controller.gateFade,
                soften: controller.gateSoft,
                darkTint: theme.night,
                child: ChromeWordmark(
                  size: wordmarkSize,
                  night: theme.night,
                ),
              ),
            ),
            // 上滑提示。
            Positioned(
              top: h * 0.8853,
              height: 22 * sx,
              left: 0,
              right: 0,
              child: SoftCopyBlock(
                fade: controller.hintFade,
                soften: controller.hintSoft,
                darkTint: theme.night,
                shift: Offset(
                  controller.sloshX * controller.radius * 0.04,
                  controller.sloshY * controller.radius * 0.04,
                ),
                child: Center(
                  child: Text(
                    theme.copy.hint,
                    style: TextStyle(
                      color: theme.hint,
                      fontSize: 15 * sx,
                      height: 20 * sx / (15 * sx),
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1 * sx,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildOpenCopy() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final h = _size.height;
        final sx = _sx;
        final fontSize = 32 * sx;
        final bodyStyle = TextStyle(
          color: theme.ink,
          fontSize: fontSize,
          height: 38 * sx / fontSize,
          letterSpacing: -0.7 * sx,
          fontWeight: FontWeight.w500,
        );
        return Stack(
          children: [
            // 主标题 + 划线。
            Positioned(
              top: h * 0.6163,
              height: 76 * sx,
              left: 0,
              right: 0,
              child: SoftCopyBlock(
                fade: controller.bodyFade,
                soften: controller.bodySoft,
                darkTint: theme.night,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(theme.copy.headline, style: bodyStyle),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _StruckWord(
                          text: theme.copy.struck,
                          style: bodyStyle,
                          strikeColor: theme.ink,
                        ),
                        Text(' ${theme.copy.kept}', style: bodyStyle),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 旋转第三行。
            Positioned(
              top: h * 0.7032,
              height: 38 * sx,
              left: 0,
              right: 0,
              child: Center(
                child: WipeLineText(
                  text: theme.copy.phrases[controller.phraseIndex],
                  wipe: controller.wipe,
                  fade: controller.thirdFade,
                  soften: controller.thirdSoft,
                  darkTint: theme.night,
                  style: bodyStyle,
                  height: 38 * sx,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPill() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final h = _size.height;
        final sx = _sx;
        final sy = _sy;
        final shown = controller.shown;
        final live = controller.pillLive;
        return Positioned(
          top: h * 0.8848,
          left: 50 * sx,
          right: 50 * sx,
          height: 58.7 * sy,
          child: IgnorePointer(
            ignoring: !live,
            child: Opacity(
              opacity: shown,
              child: Transform.translate(
                offset: Offset(0, (1 - shown) * 10 * sy),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Color.lerp(theme.pillFrom, theme.pillTo, shown),
                  ),
                  child: Material(
                    color: const Color(0x00000000),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: widget.onEnter,
                      child: Center(
                        child: Text(
                          theme.copy.cta,
                          style: TextStyle(
                            color: theme.pillText,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 次入口：通过 GitHub 进入（打开仓库页并同样完成进入）。
  Widget _buildGithubEntry() {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final h = _size.height;
        final shown = controller.shown;
        final live = controller.pillLive;
        return Positioned(
          top: h * 0.8848 - 34,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !live,
            child: Opacity(
              opacity: shown * 0.85,
              child: Center(
                child: InkWell(
                  onTap: widget.onEnterViaGithub,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 14,
                          color: theme.hint,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '通过 GitHub 进入',
                          style: TextStyle(
                            color: theme.hint,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 划线词：文字 + 一条横穿的中划线。
class _StruckWord extends StatelessWidget {
  const _StruckWord({
    required this.text,
    required this.style,
    required this.strikeColor,
  });

  final String text;
  final TextStyle style;
  final Color strikeColor;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 32;
    return SizedBox(
      height: style.height != null ? fontSize * (style.height ?? 1.2) : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(text, style: style),
          Positioned(
            left: 0,
            right: 0,
            top: fontSize * 0.56,
            child: Container(
              height: fontSize * 0.104,
              color: strikeColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbClipper extends CustomClipper<Rect> {
  _OrbClipper(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  Rect getClip(Size size) {
    return Rect.fromCircle(center: center, radius: radius);
  }

  @override
  bool shouldReclip(covariant _OrbClipper oldClipper) =>
      oldClipper.center != center || oldClipper.radius != radius;
}

double _lerpClamped(double x, double x0, double x1, double y0, double y1) {
  if (x1 == x0) return y0;
  final t = ((x - x0) / (x1 - x0)).clamp(0.0, 1.0);
  return y0 + (y1 - y0) * t;
}
