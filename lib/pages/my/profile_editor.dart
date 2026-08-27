import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/widget/frosted_surface.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';

/// 「我的追番」用户资料编辑器：自定义用户名与头像。
///
/// 头像存为应用文档目录下的 `avatar.png`（选择时已压缩到最长边 512、
/// 质量 85），设置里只记绝对路径；用户名存 setting，空串回退默认。
/// 返回 true 表示有修改，调用方刷新展示。
Future<bool> showProfileEditor(BuildContext context) async {
  final result = await MiruDialog.show<bool>(
    clickMaskDismiss: true,
    builder: (context) => const _ProfileEditorDialog(),
  );
  return result ?? false;
}

class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog();

  @override
  State<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<_ProfileEditorDialog> {
  late final TextEditingController _nameController;
  String? _avatarPath;
  bool _saving = false;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(24));

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: GStorage.getSetting(SettingsKeys.username));
    _avatarPath = GStorage.getSetting(SettingsKeys.avatarPath);
    if ((_avatarPath ?? '').isNotEmpty &&
        !File(_avatarPath!).existsSync()) {
      // 卸载重装/文件被清理后的悬空路径，直接视为未设置。
      _avatarPath = null;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return;

      final docDir = await getApplicationDocumentsDirectory();
      final avatarFile = File('${docDir.path}/avatar.png');
      await File(picked.path).copy(avatarFile.path);

      setState(() => _avatarPath = avatarFile.path);
    } catch (e) {
      MiruLogger().w('Profile: pick avatar failed', error: e);
      if (mounted) {
        MiruDialog.showToast(message: '选择头像失败，请重试');
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await GStorage.putSetting(
        SettingsKeys.username,
        _nameController.text.trim(),
      );
      await GStorage.putSetting(
        SettingsKeys.avatarPath,
        _avatarPath ?? '',
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(true);
      }
    } catch (e) {
      MiruLogger().w('Profile: save failed', error: e);
      if (mounted) {
        setState(() => _saving = false);
        MiruDialog.showToast(message: '保存失败，请重试');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: FrostedSurface(
        borderRadius: _radius,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 0.8,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: _radius,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('编辑资料',
                    style: textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _AvatarPreview(path: _avatarPath),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextButton.icon(
                            onPressed: _pickAvatar,
                            icon: const Icon(Icons.photo_library_outlined,
                                size: 18),
                            label: const Text('更换头像'),
                          ),
                          if (_avatarPath != null)
                            TextButton(
                              onPressed: () =>
                                  setState(() => _avatarPath = null),
                              child: Text(
                                '移除头像',
                                style: TextStyle(
                                    color: colorScheme.outline),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  maxLength: 12,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    hintText: '留空显示「我的追番」',
                    counterText: '',
                    border: OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context, rootNavigator: true).pop(false),
                      child: Text(
                        '取消',
                        style: TextStyle(color: colorScheme.outline),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AvatarPreview extends StatelessWidget {
  const _AvatarPreview({this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.primaryContainer,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: ClipOval(
        child: path != null
            ? Image.file(
                File(path!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.favorite_rounded,
                  size: 30,
                  color: colorScheme.onPrimaryContainer,
                ),
              )
            : Icon(
                Icons.favorite_rounded,
                size: 30,
                color: colorScheme.onPrimaryContainer,
              ),
      ),
    );
  }
}
