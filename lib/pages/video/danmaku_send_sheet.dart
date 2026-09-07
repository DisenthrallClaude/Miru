import 'package:flutter/material.dart';

Future<String?> showMobileDanmakuInputSheet(BuildContext context) {
  // 播放器路径禁止 BackdropFilter（Impeller 下每帧采样整幅视频纹理，
  // 低端机直接掉帧），改用高不透明度表面色模拟「厚玻璃」质感。
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<String>(
    context: context,
    elevation: 0,
    // 统一补拖拽把手：全 app 的自适应 sheet 都没有把手，这个入口又
    // 绕开了统一入口直接用原生 sheet，至少带上 Material 自带把手。
    showDragHandle: true,
    backgroundColor: scheme.surface.withValues(alpha: 0.94),
    shape: BeveledRectangleBorder(
      side: BorderSide(color: scheme.outlineVariant, width: 0.5),
    ),
    isScrollControlled: true,
    builder: (context) => const _MobileDanmakuInputSheet(),
  );
}

class _MobileDanmakuInputSheet extends StatefulWidget {
  const _MobileDanmakuInputSheet();

  @override
  State<_MobileDanmakuInputSheet> createState() =>
      _MobileDanmakuInputSheetState();
}

class _MobileDanmakuInputSheetState extends State<_MobileDanmakuInputSheet> {
  String _danmakuText = '';

  void _submit([String? value]) {
    Navigator.of(context).pop(value ?? _danmakuText);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
        left: 8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              // 34→64：兼容系统大字号与下方字数计数器（counter 属于
              // InputDecoration，会占额外 ~16dp 高度）。
              constraints: const BoxConstraints(maxHeight: 64),
              child: TextField(
                style: const TextStyle(fontSize: 15),
                autofocus: true,
                textInputAction: TextInputAction.send,
                textAlignVertical: TextAlignVertical.center,
                // 发送侧在 video_page 里对 >100 才事后报「弹幕内容过长」，
                // 输入时就让用户看到边界，超限事后才 toast 的体验太晚。
                maxLength: 100,
                onChanged: (value) => _danmakuText = value,
                onSubmitted: _submit,
                decoration: const InputDecoration(
                  filled: true,
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                  hintText: '发个友善的弹幕见证当下',
                  hintStyle: TextStyle(fontSize: 14),
                  alignLabelWithHint: true,
                  contentPadding:
                      EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '发送',
            onPressed: _submit,
            icon: Icon(
              Icons.send_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
