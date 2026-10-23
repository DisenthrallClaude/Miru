import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 播放页手势反馈层（P2-4）。
///
/// 三件东西，都只负责「看得见的回应」，不参与命中测试（全部 IgnorePointer），
/// 所以不会改变既有手势竞技场的胜负：
///
/// * [DoubleTapSeekRipple]：双击左/右区快退/快进时，从屏幕边缘涌出的
///   半月形光晕 + 点击处水波 + 三枚依次点亮的箭头 + 累计秒数。连续双击
///   同一侧会把秒数累加（+10 → +20 → +30），与实际 seekBy 次数一致。
/// * [SwipeFullscreenHint]：中部纵滑切换全屏时的跟手提示——进度环随手指
///   填满，跨过阈值换成「松手…」文案并轻微放大。
/// * [GestureCoachOverlay]：首次进入全屏时的一次性手势导览，四秒后自行
///   淡出，此后不再出现。
class DoubleTapRippleController extends ChangeNotifier {
  int _side = 0;
  int _seconds = 0;
  int _serial = 0;
  Offset? _origin;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前侧：-1 左（快退），1 右（快进），0 无。
  int get side => _side;

  /// 本轮累计秒数（正数）。
  int get seconds => _seconds;

  /// 每次触发自增，用于驱动水波重播。
  int get serial => _serial;

  /// 本次点击在播放器内的本地坐标。
  Offset? get origin => _origin;

  /// 连续双击判定窗口：上次触发后此时间内、同一侧再次触发则累加秒数。
  static const Duration accumulateWindow = Duration(milliseconds: 900);

  void trigger({required int side, required int seconds, Offset? origin}) {
    final now = DateTime.now();
    if (side == _side && now.difference(_lastAt) < accumulateWindow) {
      _seconds += seconds;
    } else {
      _side = side;
      _seconds = seconds;
    }
    _lastAt = now;
    _origin = origin;
    _serial++;
    notifyListeners();
  }

  void clear() {
    if (_side == 0) return;
    _side = 0;
    _seconds = 0;
    notifyListeners();
  }
}

class DoubleTapSeekRipple extends StatefulWidget {
  const DoubleTapSeekRipple({
    super.key,
    required this.controller,
    this.disableAnimations = false,
  });

  final DoubleTapRippleController controller;
  final bool disableAnimations;

  @override
  State<DoubleTapSeekRipple> createState() => _DoubleTapSeekRippleState();
}

class _DoubleTapSeekRippleState extends State<DoubleTapSeekRipple>
    with TickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _chevrons = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  Timer? _hideTimer;
  bool _visible = false;
  int _lastSerial = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTrigger);
  }

  @override
  void didUpdateWidget(covariant DoubleTapSeekRipple oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTrigger);
      widget.controller.addListener(_onTrigger);
    }
  }

  void _onTrigger() {
    final c = widget.controller;
    if (c.side == 0) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (c.serial == _lastSerial) return;
    _lastSerial = c.serial;
    setState(() => _visible = true);
    if (!widget.disableAnimations) {
      _wave.forward(from: 0);
      if (!_chevrons.isAnimating) _chevrons.repeat();
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 750), () {
      if (!mounted) return;
      setState(() => _visible = false);
      _chevrons.stop();
      Future<void>.delayed(const Duration(milliseconds: 260), () {
        if (mounted && !_visible) widget.controller.clear();
      });
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTrigger);
    _hideTimer?.cancel();
    _wave.dispose();
    _chevrons.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final int side = c.side;
    final bool forward = side >= 0;
    final textTheme = Theme.of(context).textTheme;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible && side != 0 ? 1 : 0,
        duration: widget.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: LayoutBuilder(builder: (context, constraints) {
          final double w = constraints.maxWidth;
          final double h = constraints.maxHeight;
          if (w <= 0 || h <= 0 || side == 0) return const SizedBox.shrink();
          final double bandWidth = w * 0.38;
          return Stack(children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: forward ? null : 0,
              right: forward ? 0 : null,
              width: bandWidth,
              child: ClipPath(
                clipper: _CrescentClipper(fromRight: forward),
                child: AnimatedBuilder(
                  animation: _wave,
                  builder: (context, _) {
                    final Offset? o = c.origin;
                    final Offset local = o == null
                        ? Offset(bandWidth / 2, h / 2)
                        : Offset(forward ? o.dx - (w - bandWidth) : o.dx, o.dy);
                    return CustomPaint(
                      painter: _RipplePainter(
                        progress: _wave.value,
                        origin: local,
                        fromRight: forward,
                      ),
                      child: const SizedBox.expand(),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              left: forward ? null : 0,
              right: forward ? 0 : null,
              width: bandWidth,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _chevrons,
                      builder: (context, _) => _Chevrons(
                        progress: _chevrons.value,
                        forward: forward,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween(begin: 0.86, end: 1.0).animate(
                            CurvedAnimation(
                                parent: anim, curve: Curves.easeOutBack),
                          ),
                          child: child,
                        ),
                      ),
                      child: Text(
                        '${forward ? '快进' : '快退'} ${c.seconds} 秒',
                        key: ValueKey(c.seconds * side),
                        style: textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          shadows: const [
                            Shadow(color: Colors.black54, blurRadius: 8),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

/// 贴屏幕边缘的半月形：外沿是直边，内沿是一道大弧。
class _CrescentClipper extends CustomClipper<Path> {
  const _CrescentClipper({required this.fromRight});

  final bool fromRight;

  @override
  Path getClip(Size size) {
    final path = Path();
    final double bulge = size.width * 0.32;
    if (fromRight) {
      path.moveTo(size.width, 0);
      path.lineTo(bulge, 0);
      path.quadraticBezierTo(-bulge * 0.9, size.height / 2, bulge, size.height);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width - bulge, 0);
      path.quadraticBezierTo(size.width + bulge * 0.9, size.height / 2,
          size.width - bulge, size.height);
      path.lineTo(0, size.height);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _CrescentClipper oldClipper) =>
      oldClipper.fromRight != fromRight;
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.progress,
    required this.origin,
    required this.fromRight,
  });

  final double progress;
  final Offset origin;
  final bool fromRight;

  @override
  void paint(Canvas canvas, Size size) {
    // 底色：自边缘向内渐隐的柔光，不用 BackdropFilter（视频层之上
    // 叠 saveLayer 会触发 Impeller 原生崩溃，见 flutter#185506）。
    final Rect rect = Offset.zero & size;
    final gradient = LinearGradient(
      begin: fromRight ? Alignment.centerRight : Alignment.centerLeft,
      end: fromRight ? Alignment.centerLeft : Alignment.centerRight,
      colors: [
        Colors.white.withValues(alpha: 0.16),
        Colors.white.withValues(alpha: 0.05),
      ],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));

    if (progress <= 0 || progress >= 1) return;
    final double eased = Curves.easeOutCubic.transform(progress);
    final double maxR = math.sqrt(
        size.width * size.width + size.height * size.height);
    final double radius = maxR * eased;
    final double alpha = 0.22 * (1 - progress);
    canvas.drawCircle(
      origin,
      radius,
      Paint()..color = Colors.white.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) =>
      old.progress != progress ||
      old.origin != origin ||
      old.fromRight != fromRight;
}

/// 三枚箭头依次点亮（相位错开 1/3），形成向前流动的节奏。
class _Chevrons extends StatelessWidget {
  const _Chevrons({required this.progress, required this.forward});

  final double progress;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    final children = List<Widget>.generate(3, (i) {
      // 翻转由外层 Transform.flip 负责，这里始终按「从里往外」编号。
      final double phase = (progress - i / 3) % 1.0;
      final double glow = phase < 0.5 ? 1 - phase * 2 : 0.0;
      final double opacity = 0.28 + 0.72 * glow;
      return Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: const Icon(
          Icons.play_arrow_rounded,
          color: Colors.white,
          size: 22,
          shadows: [Shadow(color: Colors.black45, blurRadius: 6)],
        ),
      );
    });
    return Transform.flip(
      flipX: !forward,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// 中部纵滑切换全屏的跟手提示。
///
/// [progress] 为 0~1+ 的跟手进度（≥1 视为已越过阈值），null 表示不显示。
class SwipeFullscreenHint extends StatelessWidget {
  const SwipeFullscreenHint({
    super.key,
    required this.progress,
    required this.exiting,
  });

  final ValueListenable<double?> progress;

  /// true = 下滑退出全屏；false = 上滑进入全屏。
  final bool exiting;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, value, _) {
          final bool visible = value != null && value > 0.04;
          final double p = (value ?? 0).clamp(0.0, 1.0);
          final bool armed = (value ?? 0) >= 1.0;
          final String label = exiting
              ? (armed ? '松手退出全屏' : '下滑退出全屏')
              : (armed ? '松手进入全屏' : '上滑进入全屏');
          return AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Align(
              alignment: exiting
                  ? const Alignment(0, -0.62)
                  : const Alignment(0, 0.62),
              child: Transform.translate(
                offset: Offset(0, (exiting ? 1 : -1) * 18 * p),
                child: AnimatedScale(
                  scale: armed ? 1.06 : 1.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: armed ? 0.5 : 0.18),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: Stack(alignment: Alignment.center, children: [
                            CircularProgressIndicator(
                              value: p,
                              strokeWidth: 2,
                              color: Colors.white,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.18),
                            ),
                            Icon(
                              exiting
                                  ? Icons.fullscreen_exit_rounded
                                  : Icons.fullscreen_rounded,
                              size: 12,
                              color: Colors.white,
                            ),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 首次全屏的手势导览：三栏分区 + 底部两条补充说明，4 秒后淡出。
class GestureCoachOverlay extends StatefulWidget {
  const GestureCoachOverlay({
    super.key,
    required this.visible,
    this.brightnessVolumeEnabled = true,
  });

  final bool visible;
  final bool brightnessVolumeEnabled;

  @override
  State<GestureCoachOverlay> createState() => _GestureCoachOverlayState();
}

class _GestureCoachOverlayState extends State<GestureCoachOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant GestureCoachOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!widget.visible && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  Widget _zone(BuildContext context, IconData icon, String title, String sub) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _breath,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, -4 + 8 * Curves.easeInOut.transform(_breath.value)),
            child: child,
          ),
          child: Icon(icon, color: Colors.white, size: 30),
        ),
        const SizedBox(height: 10),
        Text(title,
            style: textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 2)),
        const SizedBox(height: 4),
        Text(sub,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall
                ?.copyWith(color: Colors.white.withValues(alpha: 0.72))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final divider = Container(
      width: 1,
      margin: const EdgeInsets.symmetric(vertical: 48),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.35),
            Colors.white.withValues(alpha: 0),
          ],
        ),
      ),
    );
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        child: Container(
          color: Colors.black.withValues(alpha: 0.58),
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: widget.brightnessVolumeEnabled
                            ? _zone(context, Icons.wb_sunny_outlined, '亮度',
                                '左侧上下滑动\n双击快退')
                            : _zone(context, Icons.fast_rewind_rounded, '快退',
                                '左侧双击'),
                      ),
                    ),
                    divider,
                    Expanded(
                      child: Center(
                        child: _zone(context, Icons.swipe_down_rounded,
                            '退出全屏', '中间向下轻扫\n双击暂停 · 长按倍速'),
                      ),
                    ),
                    divider,
                    Expanded(
                      child: Center(
                        child: widget.brightnessVolumeEnabled
                            ? _zone(context, Icons.volume_up_outlined, '音量',
                                '右侧上下滑动\n双击快进')
                            : _zone(context, Icons.fast_forward_rounded, '快进',
                                '右侧双击'),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.swap_horiz_rounded,
                        color: Colors.white70, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '左右滑动 · 拖动进度',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.white70, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
