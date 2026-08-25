
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/card/network_img_layer.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/utils/theme.dart';

/// 推荐页信息流组件（仿腾讯视频布局）。
///
/// 纯展示层：只消费 `BangumiItem` 已有字段，不发起任何请求、不碰 Controller。
/// 点击行为与原卡片一致 —— `context.pushNamed('/info/', arguments: item)`。
///

// ---------------------------------------------------------------------------
// 从既有字段派生展示信息（没有"更新至 x 集"这种字段，不臆造）
// ---------------------------------------------------------------------------

String _yearOf(BangumiItem item) {
  final d = item.airDate;
  if (d.length >= 4) return d.substring(0, 4);
  return '';
}

/// 右上角角标。优先「新番」，其次「高分」，再次首个标签。
String? _badgeOf(BangumiItem item) {
  final year = _yearOf(item);
  final nowYear = DateTime.now().year.toString();
  if (year == nowYear) return '新番';
  if (item.ratingScore >= 8.0 && item.votes > 100) return '高分';
  if (item.tags.isNotEmpty) {
    final t = item.tags.first.name.trim();
    if (t.isNotEmpty && t.characters.length <= 4) return t;
  }
  return null;
}

/// 图片右下角覆盖信息：有评分显示评分，否则显示年份。
String? _cornerInfoOf(BangumiItem item) {
  if (item.ratingScore > 0) return '${item.ratingScore.toStringAsFixed(1)} 分';
  final y = _yearOf(item);
  return y.isEmpty ? null : '$y 年';
}

/// 标题下方的灰色副标题：简介首句，回落到标签。
String _subtitleOf(BangumiItem item) {
  final s = item.summary.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isNotEmpty) {
    final cut = s.split(RegExp(r'[。！？.!?]')).firstWhere(
          (e) => e.trim().isNotEmpty,
          orElse: () => s,
        );
    return cut.length > 40 ? '${cut.substring(0, 40)}…' : cut;
  }
  if (item.tags.isNotEmpty) {
    return item.tags.take(3).map((e) => e.name).join(' · ');
  }
  return item.name;
}

// ---------------------------------------------------------------------------
// 角标 / 覆盖层
// ---------------------------------------------------------------------------

class _CornerBadge extends StatelessWidget {
  const _CornerBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(Radii.sm),
          bottomLeft: Radius.circular(Radii.sm),
        ),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
      ),
    );
  }
}

/// 图片底部渐变压暗，保证覆盖文字可读。
///
/// 刻意**不**返回 `Positioned` —— 那样它就只能直接放在 Stack 下，
/// 一旦被 ClipRRect 之类包一层就会触发 ParentDataWidget 断言。
/// 由调用方自己用 `Positioned.fill` 包裹。
class _BottomScrim extends StatelessWidget {
  const _BottomScrim({this.height = 0.45, this.borderRadius});
  final double height;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          stops: [0.0, height],
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 横向卡片（两列网格用）
// ---------------------------------------------------------------------------

class BangumiFeedCard extends StatelessWidget {
  const BangumiFeedCard({super.key, required this.bangumiItem});

  final BangumiItem bangumiItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = _badgeOf(bangumiItem);
    final corner = _cornerInfoOf(bangumiItem);

    return InkWell(
      borderRadius: Radii.brMd,
      onTap: () => context.pushNamed('/info/', arguments: bangumiItem),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: LayoutBuilder(builder: (context, c) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  NetworkImgLayer(
                    src: bangumiItem.images['large'] ?? '',
                    width: c.maxWidth,
                    height: c.maxHeight,
                    origAspectRatio: 0.65,
                    alignment: Alignment.topCenter,
                    borderRadius: Radii.brMd,
                  ),
                  const Positioned.fill(
                    child: _BottomScrim(borderRadius: Radii.brMd),
                  ),
                  if (corner != null)
                    Positioned(
                      right: 8,
                      bottom: 6,
                      child: Text(
                        corner,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(blurRadius: 3, color: Colors.black54),
                          ],
                        ),
                      ),
                    ),
                  if (badge != null)
                    Positioned(top: 0, right: 0, child: _CornerBadge(text: badge)),
                ],
              );
            }),
          ),
          const SizedBox(height: Space.sm),
          Text(
            bangumiItem.nameCn.isNotEmpty
                ? bangumiItem.nameCn
                : bangumiItem.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _subtitleOf(bangumiItem),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 竖版卡片（信息流网格用）
// ---------------------------------------------------------------------------

/// 竖版海报卡片。
///
/// 与横版的区别：按封面原始比例（约 0.65）完整展示，不做裁切，
/// 因此不会切掉人物头部——Bangumi 的封面本来就是竖图。
class BangumiFeedCardV extends StatelessWidget {
  const BangumiFeedCardV({
    super.key,
    required this.bangumiItem,
    this.onImageLoaded,
  });

  final BangumiItem bangumiItem;

  /// 封面加载完成回调，供信息流做「先加载完的排前面」。
  final VoidCallback? onImageLoaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = _badgeOf(bangumiItem);
    final corner = _cornerInfoOf(bangumiItem);
    final ts = MediaQuery.textScalerOf(context);

    return InkWell(
      borderRadius: Radii.brMd,
      onTap: () => context.pushNamed('/info/', arguments: bangumiItem),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 0.65,
            child: LayoutBuilder(builder: (context, c) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  NetworkImgLayer(
                    src: bangumiItem.images['large'] ?? '',
                    width: c.maxWidth,
                    height: c.maxHeight,
                    origAspectRatio: 0.65,
                    borderRadius: Radii.brMd,
                    onLoaded: onImageLoaded,
                  ),
                  if (corner != null)
                    const Positioned.fill(
                      child: _BottomScrim(
                        height: 0.32,
                        borderRadius: Radii.brMd,
                      ),
                    ),
                  if (corner != null)
                    Positioned(
                      right: 6,
                      bottom: 5,
                      child: Text(
                        corner,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(blurRadius: 3, color: Colors.black54),
                          ],
                        ),
                      ),
                    ),
                  if (badge != null)
                    Positioned(
                        top: 0, right: 0, child: _CornerBadge(text: badge)),
                ],
              );
            }),
          ),
          const SizedBox(height: Space.sm),
          Text(
            bangumiItem.nameCn.isNotEmpty
                ? bangumiItem.nameCn
                : bangumiItem.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textScaler: ts.clamp(maxScaleFactor: 1.1),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

