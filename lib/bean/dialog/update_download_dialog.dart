import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/services/update/mirror_downloader.dart';

/// v1.8.1：更新下载进度弹窗（液态玻璃白卡，与「发现新版本」同一视觉）。
///
/// 展示：阶段（测速选源 / 下载 / 校验）、流动高光进度条、已下/总量、
/// 实时速度、剩余时间、当前在用的下载源（多镜像并发时显示多个）。
class UpdateDownloadDialog extends StatelessWidget {
  const UpdateDownloadDialog({
    super.key,
    required this.version,
    required this.progress,
    required this.onCancel,
    required this.onBrowser,
  });

  final String version;
  final ValueListenable<DownloadProgress> progress;
  final VoidCallback onCancel;
  final VoidCallback onBrowser;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(26));
  static const Color _ink = Color(0xFF1F2328);
  static const Color _inkSoft = Color(0xFF57606A);
  static const Color _accent = Color(0xFF2563EB);

  static String mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  static String speedText(double bps) {
    if (bps <= 0) return '—';
    if (bps >= 1048576) return '${(bps / 1048576).toStringAsFixed(2)} MB/s';
    return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  }

  static String etaText(Duration? d) {
    if (d == null) return '—';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? '$m 分 $s 秒' : '$s 秒';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: _radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.26),
                blurRadius: 36,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: FrostedSurface(
            borderRadius: _radius,
            tint: Colors.white,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.55), width: 1),
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
                child: ValueListenableBuilder<DownloadProgress>(
                  valueListenable: progress,
                  builder: (context, p, _) => _body(context, p),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, DownloadProgress p) {
    final String phase;
    switch (p.phase) {
      case DownloadPhase.probing:
        phase = p.round > 1 ? '重新测速选源（第 ${p.round} 轮）…' : '正在测速，挑选最快的下载源…';
      case DownloadPhase.downloading:
        phase = p.resumedBytes > 0
            ? '多线程下载中 · 已从断点续传 ${mb(p.resumedBytes)} MB'
            : '多线程下载中';
      case DownloadPhase.verifying:
        phase = '下载完成，正在校验完整性…';
    }
    final fraction = p.phase == DownloadPhase.probing ? null : p.fraction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(CupertinoIcons.arrow_down_circle,
              size: 22, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('正在下载 $version',
                style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    color: _ink)),
          ),
          if (fraction != null)
            Text('${(fraction * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _accent,
                    fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        const SizedBox(height: 6),
        Text(phase, style: const TextStyle(fontSize: 12.5, color: _inkSoft)),
        const SizedBox(height: 16),
        LiquidProgressBar(value: fraction),
        const SizedBox(height: 14),
        Row(
          children: [
            _stat('已下载',
                p.total > 0 ? '${mb(p.received)} / ${mb(p.total)} MB' : '—'),
            _stat('速度', speedText(p.bytesPerSecond)),
            _stat('剩余', etaText(p.eta)),
          ],
        ),
        if (p.sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in p.sources)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: _accent.withValues(alpha: 0.22)),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(CupertinoIcons.bolt_fill,
                          size: 11, color: _accent),
                      const SizedBox(width: 3),
                      Text(s,
                          style: const TextStyle(
                              fontSize: 11.5, color: _accent, height: 1.2)),
                    ]),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: _inkSoft, shape: const StadiumBorder()),
              onPressed: onBrowser,
              child: const Text('浏览器下载'),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: _ink,
                side: BorderSide(color: _inkSoft.withValues(alpha: 0.35)),
                shape: const StadiumBorder(),
                minimumSize: const Size(0, 38),
              ),
              onPressed: onCancel,
              child: const Text('暂停'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: _inkSoft)),
            const SizedBox(height: 2),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      );
}

/// 液态玻璃进度条：磨砂槽 + 渐变填充 + 一道缓慢流动的高光。
/// [value] 为 null 时显示不确定态（高光来回流动）。
class LiquidProgressBar extends StatefulWidget {
  const LiquidProgressBar({super.key, this.value, this.height = 10});
  final double? value;
  final double height;

  @override
  State<LiquidProgressBar> createState() => _LiquidProgressBarState();
}

class _LiquidProgressBarState extends State<LiquidProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return SizedBox(
      height: h,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        return ClipRRect(
          borderRadius: BorderRadius.circular(h),
          child: Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2328).withValues(alpha: 0.07),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.8), width: 0.8),
                  borderRadius: BorderRadius.circular(h),
                ),
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(end: widget.value ?? 0.28),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) {
                return AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    final t = reduce ? 0.5 : _c.value;
                    final fillW = widget.value == null ? w * 0.28 : w * v;
                    final left = widget.value == null
                        ? (w + fillW) * t - fillW
                        : 0.0;
                    return Positioned(
                      left: left,
                      top: 0,
                      bottom: 0,
                      width: fillW,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(h),
                          gradient: const LinearGradient(colors: [
                            Color(0xFF60A5FA),
                            Color(0xFF2563EB),
                            Color(0xFF7C3AED),
                          ]),
                        ),
                        child: widget.value == null
                            ? null
                            : ShaderMask(
                                blendMode: BlendMode.srcATop,
                                shaderCallback: (r) => LinearGradient(
                                  begin: Alignment(-1.6 + 3.2 * t, 0),
                                  end: Alignment(-0.6 + 3.2 * t, 0),
                                  colors: [
                                    Colors.white.withValues(alpha: 0),
                                    Colors.white.withValues(alpha: 0.45),
                                    Colors.white.withValues(alpha: 0),
                                  ],
                                ).createShader(r),
                                child: const SizedBox.expand(
                                    child: ColoredBox(color: Colors.white10)),
                              ),
                      ),
                    );
                  },
                );
              },
            ),
            // 顶部镜面高光
            Positioned(
              left: 2,
              right: 2,
              top: 1,
              height: h * 0.38,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(h),
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
            ),
          ]),
        );
      }),
    );
  }
}
