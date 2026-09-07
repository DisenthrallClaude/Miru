import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';

/// 全应用统一的「危险操作二次确认」对话框。
///
/// 为什么需要它：删除/清空类操作此前各页面自己拼 AlertDialog——
/// 有的确认键标 error 色（下载页），有的用默认色（历史/关于/规则），
/// 用户无法靠颜色识别破坏性操作。这里收口为一种样式：
/// 取消 = outline 次级灰、确认 = error 红，与下载页既有惯例对齐。
///
/// 返回 true = 用户确认执行；false / 关闭弹窗 = 取消。
Future<bool> showDestructiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '删除',
}) async {
  final result = await MiruDialog.show<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => MiruDialog.dismiss(popWith: false),
          child: Text(
            '取消',
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        TextButton(
          onPressed: () => MiruDialog.dismiss(popWith: true),
          child: Text(
            confirmLabel,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
