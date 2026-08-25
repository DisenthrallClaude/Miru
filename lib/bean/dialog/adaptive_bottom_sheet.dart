import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/utils/device.dart';
import 'package:miru/utils/theme.dart';

BoxConstraints adaptiveBottomSheetConstraints(
  BuildContext context, {
  double maxHeightFactor = 0.75,
  double compactLandscapeMaxHeightFactor = 0.9,
}) {
  final size = MediaQuery.sizeOf(context);
  final isLandscape = size.width > size.height;
  final isLargeScreen = size.shortestSide >= 600;
  final useFullWidth = !isLandscape && size.width < 600;
  final maxWidth =
      useFullWidth ? size.width : math.min(size.width * 0.72, 640.0);
  final useExpandedLandscapeHeight =
      isLandscape && !isDesktop() && !isLargeScreen;
  final maxHeight = size.height *
      (useExpandedLandscapeHeight
          ? compactLandscapeMaxHeightFactor
          : maxHeightFactor);

  return BoxConstraints(
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
}

/// 全应用统一的底部弹层入口：内容自动落在液态玻璃之上。
///
/// [glass] 置 false 时跳过玻璃层——播放器上方务必关闭：
/// Impeller 下 BackdropFilter 会对视频纹理逐帧采样，低端机直接掉帧。
/// 调用方传入的 [backgroundColor] 作为玻璃的色调参考。
Future<T?> showAdaptiveBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxHeightFactor = 0.75,
  double compactLandscapeMaxHeightFactor = 0.9,
  Color? backgroundColor,
  bool showDragHandle = false,
  bool glass = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    // 底色交给玻璃层，这里必须透明，否则玻璃透不出来。
    backgroundColor: glass ? Colors.transparent : null,
    elevation: 0,
    builder: (context) => glass
        ? FrostedSurface(
            tint: backgroundColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(Radii.xxl),
            ),
            child: builder(context),
          )
        : builder(context),
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: showDragHandle,
    constraints: adaptiveBottomSheetConstraints(
      context,
      maxHeightFactor: maxHeightFactor,
      compactLandscapeMaxHeightFactor: compactLandscapeMaxHeightFactor,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xxl)),
    ),
    clipBehavior: Clip.antiAlias,
  );
}
