import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

bool isTouchLikePointer(PointerDeviceKind? pointerKind) {
  return pointerKind == PointerDeviceKind.touch ||
      pointerKind == PointerDeviceKind.stylus ||
      pointerKind == PointerDeviceKind.invertedStylus;
}

bool shouldToggleControllerOnPrimaryTap({
  required bool isDesktop,
  required PointerDeviceKind? pointerKind,
}) {
  return !isDesktop || isTouchLikePointer(pointerKind);
}

bool shouldToggleFullscreenOnDoubleTap({
  required bool isDesktop,
  required bool isPip,
  required PointerDeviceKind? pointerKind,
}) {
  return isDesktop && !isPip && !isTouchLikePointer(pointerKind);
}

/// 把进度条拖动事件的拇指位置换算为媒体时间目标。
///
/// 为什么不用 `ThumbDragDetails.timeStamp`：Flutter 手势事件里 `timeStamp`
/// 惯指事件时间戳（自系统启动计的时长），该字段命名极易误读——审查轮就曾
/// 因此把它判成「拖动目标跳片尾」的真 bug（当前包版本 2.0.3 恰好把拇指
/// 所在的媒体时长填进这个字段，运行时侥幸正确）。改为从拖动位置按比例
/// 换算，语义自解释，也不随包升级的语义漂移而脆断。
///
/// 换算按整条宽度做比例（两侧时间标签造成的微小偏差在拖动预览中不可
/// 感知）；松手提交仍走 `onSeek` 回调里包内部计算的精确拇指时长。
Duration? thumbDragPositionToDuration(
  BuildContext barContext,
  Offset localPosition,
  Duration total,
) {
  final box = barContext.findRenderObject();
  if (box is! RenderBox || box.size.width <= 0) {
    return null;
  }
  final ratio = (localPosition.dx / box.size.width).clamp(0.0, 1.0);
  return Duration(
    microseconds: (total.inMicroseconds * ratio).round(),
  );
}
