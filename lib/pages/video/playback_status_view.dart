import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放器遮罩上的「加载中 / 失败」两种状态（P2-5）。
///
/// 取代原先的「Material 转圈 + 一行白字」。设计意图：
///
/// * 加载：一枚缓慢呼吸的光环 + 绕行的细弧（不是机械的匀速转圈），
///   下面是衬线体的主文案与三段式进程「解析 · 缓冲 · 开播」，当前段点亮。
///   已耗时秒数保留（v1.6.4 起的承诺：等待要有真实刻度），并在久等时
///   给出温和的下一步建议，而不是让用户对着转圈发呆。
/// * 失败：内容自下而上淡入，图标所在的色环轻微一顿（不是报错式的抖动），
///   标题克制、说明另起一行，主操作「重试」与次操作「换个线路」分层。
class PlaybackLoadingView extends StatefulWidget {
  const PlaybackLoadingView({
    super.key,
    required this.resolving,
    this.disableAnimations = false,
    this.titleOverride,
  });

  /// true = 解析层工作中；false = 已解析、播放器缓冲中。
  final bool resolving;
  final bool disableAnimations;

  /// 覆盖主文案（如「正在跳过片头广告」）。
  final String? titleOverride;

  /// 主文案（按阶段）。
  static String titleFor({required bool resolving}) =>
      resolving ? '正在寻找片源' : '片源已就绪，正在缓冲';

  /// 久等时的温和提示（按耗时）；null 表示无需提示。
  static String? hintFor(double elapsedSeconds) {
    if (elapsedSeconds >= 20) return '这条线路有些吃力，可以点右上角刷新，或换个线路';
    if (elapsedSeconds >= 8) return '线路响应偏慢，再稍等片刻';
    return null;
  }

  @override
  State<PlaybackLoadingView> createState() => _PlaybackLoadingViewState();
}

class _PlaybackLoadingViewState extends State<PlaybackLoadingView>
    with SingleTickerProviderStateMixin {
  final DateTime _startedAt = DateTime.now();
  Timer? _ticker;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.disableAnimations) _spin.repeat();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final double elapsed =
        DateTime.now().difference(_startedAt).inMilliseconds / 1000.0;
    final String? hint = PlaybackLoadingView.hintFor(elapsed);
    final Color accent = colorScheme.tertiaryContainer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 56,
          height: 56,
          child: AnimatedBuilder(
            animation: _spin,
            builder: (context, _) => CustomPaint(
              painter: _HaloPainter(t: _spin.value, color: accent),
            ),
          ),
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.25),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
              child: child,
            ),
          ),
          child: Text(
            widget.titleOverride ??
                PlaybackLoadingView.titleFor(resolving: widget.resolving),
            key: ValueKey('${widget.resolving}${widget.titleOverride}'),
            style: textTheme.titleMedium?.copyWith(
              color: Colors.white,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _StageDots(stage: widget.resolving ? 0 : 1, accent: accent),
        const SizedBox(height: 10),
        Text(
          '${elapsed.toStringAsFixed(1)}s',
          style: textTheme.labelSmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.55),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: hint == null
              ? const SizedBox(width: 0)
              : Padding(
                  padding: const EdgeInsets.only(top: 10, left: 32, right: 32),
                  child: Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 3;
    // 呼吸光环：半径与透明度随正弦缓慢起伏。
    final double breath = (math.sin(t * 2 * math.pi) + 1) / 2;
    canvas.drawCircle(
      c,
      r * (0.78 + 0.1 * breath),
      Paint()..color = color.withValues(alpha: 0.10 + 0.10 * breath),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.14),
    );
    // 绕行细弧：长度随时间伸缩，避免机械匀速感。
    final double sweep = math.pi * (0.35 + 0.45 * breath);
    final double start = t * 2 * math.pi * 2 - math.pi / 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _HaloPainter old) =>
      old.t != t || old.color != color;
}

class _StageDots extends StatelessWidget {
  const _StageDots({required this.stage, required this.accent});

  /// 0 解析、1 缓冲、2 开播。
  final int stage;
  final Color accent;

  static const List<String> labels = ['解析', '缓冲', '开播'];

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final children = <Widget>[];
    for (int i = 0; i < labels.length; i++) {
      final bool done = i < stage;
      final bool active = i == stage;
      children.add(Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          width: active ? 14 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active || done
                ? accent
                : Colors.white.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          labels[i],
          style: textTheme.labelSmall?.copyWith(
            color: Colors.white.withValues(alpha: active ? 0.9 : 0.45),
            letterSpacing: 1,
          ),
        ),
      ]));
      if (i < labels.length - 1) children.add(const SizedBox(width: 12));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class PlaybackErrorView extends StatelessWidget {
  const PlaybackErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.onSwitchRoad,
    this.disableAnimations = false,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onSwitchRoad;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.errorContainer.withValues(alpha: 0.22),
            border: Border.all(
              color: colorScheme.error.withValues(alpha: 0.45),
            ),
          ),
          child: Icon(Icons.portable_wifi_off_rounded,
              color: colorScheme.error, size: 26),
        ),
        const SizedBox(height: 18),
        Text(
          '这一集暂时没能播放',
          style: textTheme.titleMedium?.copyWith(
            color: Colors.white,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.7),
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
        if (onSwitchRoad != null) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: onSwitchRoad,
            child: const Text('换个线路'),
          ),
        ],
      ],
    );
    if (disableAnimations) return content;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      child: content,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - v)),
          child: child,
        ),
      ),
    );
  }
}
