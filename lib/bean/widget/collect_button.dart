import 'package:flutter/material.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/bean/widget/glass.dart';
import 'package:miru/utils/theme.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/pages/collect/collect_controller.dart';
import 'package:flutter_modular/flutter_modular.dart';

class CollectButton extends StatefulWidget {
  CollectButton({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
  }) {
    isExtended = false;
  }

  CollectButton.extend({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
  }) {
    isExtended = true;
  }

  final BangumiItem bangumiItem;
  final Color color;
  late final bool isExtended;
  final void Function()? onOpen;
  final void Function()? onClose;

  @override
  State<CollectButton> createState() => _CollectButtonState();
}

class _CollectButtonState extends State<CollectButton> {
  // 1. 在看
  // 2. 想看
  // 3. 搁置
  // 4. 看过
  // 5. 抛弃
  late int collectType;
  final CollectController collectController = inject<CollectController>();

  @override
  void initState() {
    super.initState();
  }

  String getTypeStringByInt(int collectType) {
    switch (collectType) {
      case 1:
        return "在看";
      case 2:
        return "想看";
      case 3:
        return "搁置";
      case 4:
        return "看过";
      case 5:
        return "抛弃";
      default:
        return "未追";
    }
  }

  IconData getIconByInt(int collectType) {
    switch (collectType) {
      case 1:
        return Icons.favorite;
      case 2:
        return Icons.star_rounded;
      case 3:
        return Icons.pending_actions;
      case 4:
        return Icons.done;
      case 5:
        return Icons.heart_broken;
      default:
        return Icons.favorite_border;
    }
  }

  @override
  Widget build(BuildContext context) {
    collectType = collectController.getCollectType(widget.bangumiItem);
    return MenuAnchor(
      consumeOutsideTap: true,
      onClose: widget.onClose,
      onOpen: widget.onOpen,
      crossAxisUnconstrained: false,
      builder: (_, MenuController controller, __) {
        if (widget.isExtended) {
          // 液态玻璃药丸：替代原先的实心 FilledButton，
          // 与全应用玻璃语言统一（悬浮在海报上时尤其通透）。
          return FrostedSurface(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.pill),
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.lg,
                    vertical: Space.sm,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        getIconByInt(collectType),
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: Space.sm),
                      Text(
                        getTypeStringByInt(collectType),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        } else {
          return IconButton(
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            tooltip: getTypeStringByInt(collectType),
            icon: Icon(
              getIconByInt(collectType),
              color: widget.color,
            ),
          );
        }
      },
      menuChildren: List<MenuItemButton>.generate(
        6,
        (int index) => MenuItemButton(
          onPressed: () async {
            if (index != collectType && mounted) {
              await collectController.addCollect(widget.bangumiItem,
                  type: index);
              // 防止状态错误刷新
              if (!mounted) {
                return;
              }
              setState(() {});
            }
          },
          child: Container(
            height: 48,
            constraints: BoxConstraints(minWidth: 112),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 图标外圈套一层玻璃圆盘；选中项带强调色调
                  GlassSurface(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    padding: const EdgeInsets.all(Space.xs),
                    tinted: index == collectType,
                    child: Icon(
                      getIconByInt(index),
                      size: 20,
                      color: index == collectType
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(width: Space.sm),
                  Text(
                    getTypeStringByInt(index),
                    style: TextStyle(
                      color: index == collectType
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      fontWeight: index == collectType
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
