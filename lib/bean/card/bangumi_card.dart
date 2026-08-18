import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/theme.dart';

// 视频卡片 - 垂直布局
class BangumiCardV extends StatelessWidget {
  const BangumiCardV({
    super.key,
    required this.bangumiItem,
    this.canTap = true,
    this.enableHero = true,
  });

  final BangumiItem bangumiItem;
  final bool canTap;
  final bool enableHero;

  @override
  Widget build(BuildContext context) {
    // 极简：去掉卡片容器与投影，只保留圆角海报 + 下方标题，
    // 让网格靠留白而非边框来分隔。
    return GestureDetector(
      child: InkWell(
        borderRadius: Radii.brMd,
        onTap: () {
          if (!canTap) {
            KazumiDialog.showToast(
              message: '编辑模式',
            );
            return;
          }
          context.pushNamed('/info/', arguments: bangumiItem);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 0.65,
              child: LayoutBuilder(builder: (context, boxConstraints) {
                final double maxWidth = boxConstraints.maxWidth;
                final double maxHeight = boxConstraints.maxHeight;
                return enableHero
                    ? Hero(
                        transitionOnUserGestures: true,
                        flightShuttleBuilder:
                            NetworkImgLayer.heroFlightShuttleBuilder,
                        tag: bangumiItem.id,
                        child: NetworkImgLayer(
                          src: bangumiItem.images['large'] ?? '',
                          width: maxWidth,
                          height: maxHeight,
                        ),
                      )
                    : NetworkImgLayer(
                        src: bangumiItem.images['large'] ?? '',
                        width: maxWidth,
                        height: maxHeight,
                      );
              }),
            ),
            BangumiContent(bangumiItem: bangumiItem)
          ],
        ),
      ),
    );
  }
}

class BangumiContent extends StatelessWidget {
  const BangumiContent({super.key, required this.bangumiItem});

  final BangumiItem bangumiItem;

  static int maxTextLinesFor(BuildContext context) {
    return isDesktop()
        ? 3
        : (isTablet() &&
                MediaQuery.of(context).orientation == Orientation.landscape)
            ? 3
            : 2;
  }

  @override
  Widget build(BuildContext context) {
    final ts = MediaQuery.textScalerOf(context);
    final int maxTextLines = maxTextLinesFor(context);

    final theme = Theme.of(context);

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxs, Space.sm, Space.xs, 0),
        child: Text(
          bangumiItem.nameCn,
          textAlign: TextAlign.start,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
            height: 1.35,
          ),
          textScaler: ts.clamp(maxScaleFactor: 1.1),
          maxLines: maxTextLines,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
