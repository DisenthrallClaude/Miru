import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/constants.dart';
import 'package:miru/bean/settings/settings_detail_scaffold.dart';
import 'package:miru/bean/settings/settings_list.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/dialog/destructive_confirm.dart';

/// Display group for the shortcut list. Functions missing from every group
/// fall back to a trailing "其他" group so new shortcuts never disappear.
class _ShortcutGroup {
  const _ShortcutGroup(this.title, this.icon, this.functions);

  final String title;
  final IconData icon;
  final List<String> functions;
}

const List<_ShortcutGroup> _shortcutGroups = [
  _ShortcutGroup('播放控制', Icons.play_arrow_rounded,
      ['playorpause', 'forward', 'rewind', 'skip', 'next', 'prev']),
  _ShortcutGroup(
      '音量', Icons.volume_up_rounded, ['volumeup', 'volumedown', 'togglemute']),
  _ShortcutGroup('画面与弹幕', Icons.fullscreen_rounded,
      ['fullscreen', 'exitfullscreen', 'screenshot', 'toggledanmaku']),
  _ShortcutGroup('倍速', Icons.speed_rounded,
      ['speed1', 'speed2', 'speed3', 'speedup', 'speeddown']),
];

class KeyboardSettingsPage extends StatefulWidget {
  const KeyboardSettingsPage({super.key});

  @override
  State<KeyboardSettingsPage> createState() => _KeyboardSettingsPageState();
}

class _KeyboardSettingsPageState extends State<KeyboardSettingsPage> {
  String? listeningFunction;
  int? listeningIndex;

  /// Value the listening slot held before recording started; empty means the
  /// slot was newly added and should be dropped when recording is cancelled.
  String originalValue = '';

  late Map<String, List<String>> shortcuts;

  final FocusNode focusNode = FocusNode();

  bool get isListening => listeningFunction != null && listeningIndex != null;

  @override
  void initState() {
    super.initState();
    // 根据默认快捷键生成可用快捷键列表，并读取已设置值。
    // 旧版实现可能把 '' / '...' 占位符持久化过，甚至把配置存成空列表
    // （单绑定进入录制后直接退出页面）；界面保证每个功能至少保留一个
    // 真实绑定，读入时清理占位符、空配置恢复默认，有变化则回写
    shortcuts = {};
    for (final key in defaultShortcuts.keys) {
      final stored = GStorage.getStringListSettingByName(
        'shortcut_$key',
        defaultValue: defaultShortcuts[key]!.toList(),
      );
      final keys =
          stored.where((value) => value.isNotEmpty && value != '...').toList();
      var changed = keys.length != stored.length;
      if (keys.isEmpty) {
        keys.addAll(defaultShortcuts[key]!);
        changed = true;
      }
      if (changed) {
        GStorage.putStringListSettingByName('shortcut_$key', keys);
      }
      shortcuts[key] = keys;
    }
  }

  @override
  void dispose() {
    cancelListening();
    focusNode.dispose();
    super.dispose();
  }

  /// Restores or removes the pending slot so no '...' placeholder is left
  /// behind when recording moves elsewhere. Pure state mutation: build-path
  /// callers wrap it in setState, dispose calls it bare.
  void cancelListening() {
    if (!isListening) return;
    final func = listeningFunction!;
    final keys = shortcuts[func]!;
    final index = listeningIndex!;
    if (index < keys.length) {
      if (originalValue.isEmpty) {
        keys.removeAt(index);
      } else {
        keys[index] = originalValue;
      }
    }
    GStorage.putStringListSettingByName('shortcut_$func', keys);
    listeningFunction = null;
    listeningIndex = null;
    originalValue = '';
  }

  void beginListening(String func, int index) {
    originalValue = shortcuts[func]![index];
    shortcuts[func]![index] = '...';
    listeningFunction = func;
    listeningIndex = index;

    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      focusNode.requestFocus();
    });
  }

  bool handleShortcutInput(String rawKey) {
    if (!isListening || rawKey.isEmpty) return false;

    final func = listeningFunction!;
    final index = listeningIndex!;

    // 冲突规避
    for (final entry in shortcuts.entries) {
      final otherFunc = entry.key;
      final otherKeys = entry.value;

      for (int i = 0; i < otherKeys.length; i++) {
        if (otherFunc == func && i == index) continue;
        if (otherKeys[i] == rawKey) {
          final name = shortcutsChineseName[otherFunc] ?? otherFunc;
          MiruDialog.showToast(message: "按键已被【$name】占用，请重新输入");
          return true;
        }
      }
    }
    setState(() {
      shortcuts[func]![index] = rawKey;
      listeningFunction = null;
      listeningIndex = null;
      originalValue = '';
    });
    GStorage.putStringListSettingByName('shortcut_$func', shortcuts[func]!);

    return true;
  }

  // 新槽位不落盘：录制成功或取消时才持久化，storage 里永远没有占位符
  void onAddKey(String func) {
    setState(() {
      cancelListening();
      final keys = shortcuts[func]!;
      keys.add('');
      beginListening(func, keys.length - 1);
    });
  }

  void onKeyCapTap(String func, int index) {
    if (listeningFunction == func && listeningIndex == index) {
      setState(cancelListening);
      return;
    }
    final keyValue = shortcuts[func]![index];
    setState(() {
      cancelListening();
      // 取消可能移除了同列表中的待录制项，按值重新定位（同一功能内按键唯一）
      final idx = shortcuts[func]!.indexOf(keyValue);
      if (idx >= 0) {
        beginListening(func, idx);
      }
    });
  }

  void onRemoveKey(String func, int index) {
    final keyValue = shortcuts[func]![index];
    setState(() {
      cancelListening();
      final keys = shortcuts[func]!;
      keys.remove(keyValue);
      GStorage.putStringListSettingByName('shortcut_$func', keys);
    });
  }

  Future<void> restoreDefaults() async {
    // 快捷键是用户长期定制的数据，一键无确认全灭不可接受
    // （对照播放/弹幕设置的恢复默认均有确认）。
    final confirmed = await showDestructiveConfirm(
      context,
      title: '恢复默认快捷键',
      message: '将把所有按键映射重置为默认值，当前的自定义绑定不可恢复。',
      confirmLabel: '恢复默认',
    );
    if (!confirmed) return;
    setState(() {
      listeningFunction = null;
      listeningIndex = null;
      originalValue = '';
      for (final func in shortcuts.keys) {
        shortcuts[func] = defaultShortcuts[func]?.toList() ?? [];
        GStorage.putStringListSettingByName('shortcut_$func', shortcuts[func]!);
      }
    });
    MiruDialog.showToast(message: '已恢复默认快捷键');
  }

  List<_ShortcutGroup> get displayGroups {
    final groups = <_ShortcutGroup>[];
    final covered = <String>{};
    for (final group in _shortcutGroups) {
      final funcs = group.functions.where(shortcuts.containsKey).toList();
      covered.addAll(funcs);
      if (funcs.isNotEmpty) {
        groups.add(_ShortcutGroup(group.title, group.icon, funcs));
      }
    }
    final leftovers =
        shortcuts.keys.where((func) => !covered.contains(func)).toList();
    if (leftovers.isNotEmpty) {
      groups.add(_ShortcutGroup('其他', Icons.keyboard_rounded, leftovers));
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SettingsDetailScaffold(
      title: const Text('操作设置'),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_backup_restore_rounded),
          tooltip: '恢复默认',
          onPressed: restoreDefaults,
        ),
      ],
      body: FocusScope(
        autofocus: true,
        child: Focus(
          focusNode: focusNode,
          autofocus: true,
          canRequestFocus: true,
          skipTraversal: true,
          descendantsAreFocusable: true,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (!isListening) return KeyEventResult.ignored;

            final rawKey = event.logicalKey.keyLabel.isNotEmpty
                ? event.logicalKey.keyLabel
                : event.logicalKey.debugName ?? '';

            final handled = handleShortcutInput(rawKey);
            return handled ? KeyEventResult.handled : KeyEventResult.ignored;
          },
          child: SettingsList(
            maxWidth: 1000,
            sections: [
              Padding(
                // SettingsList 每个section 自带 16 水平 margin，提示行
                // 手动对齐同一内边距。
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Center(
                  child: Text(
                    '点按按键标签，再按下新按键完成修改',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              // 与设置中心其余页面同一套玻璃分组列表
              // （此前是独立 Card，同一设置中心两种列表语言）。
              for (final group in displayGroups) _buildGroupSection(group),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupSection(_ShortcutGroup group) {
    final colorScheme = Theme.of(context).colorScheme;
    return SettingsSection(
      title: Row(
        children: [
          Icon(group.icon, size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(group.title),
        ],
      ),
      tiles: [
        for (final func in group.functions) _buildShortcutRow(func),
      ],
    );
  }

  Widget _buildShortcutRow(String func) {
    final textTheme = Theme.of(context).textTheme;
    final keys = shortcuts[func]!;

    return Padding(
      // 行内容进玻璃分组后由外层提供水平间距，这里只留垂直呼吸。
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(shortcutsChineseName[func] ?? func, style: textTheme.bodyMedium),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                for (int i = 0; i < keys.length; i++)
                  _buildKeyCap(func, keys, i),
                _AddKeyButton(onTap: () => onAddKey(func)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyCap(String func, List<String> keys, int i) {
    final listening = listeningFunction == func && listeningIndex == i;
    // 删除入口只按真实绑定数判定，待录制占位符不算数——
    // 否则单绑定时点「添加」会让原按键出现删除按钮，可被误删成空绑定
    final realCount = keys.where((value) => value != '...').length;
    return _KeyCap(
      label: listening ? '按任意键' : keyAliases[keys[i]] ?? keys[i],
      listening: listening,
      onTap: () => onKeyCapTap(func, i),
      onDelete:
          realCount >= 2 && !listening ? () => onRemoveKey(func, i) : null,
    );
  }
}

/// Tonal keycap pill for one bound key; tap to re-record, tap again to
/// cancel. Shows a close icon when the function has spare bindings.
class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.label,
    required this.listening,
    required this.onTap,
    this.onDelete,
  });

  final String label;
  final bool listening;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: listening
          ? colorScheme.primaryContainer
          : colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: textTheme.labelMedium?.copyWith(
                  color: listening
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: 4),
                // 删除是高频微操作，此前 14px 图标热区仅 ~18dp，
                // 手机上易误触相邻 keycap——用 IconButton 撴到 40×40。
                IconButton(
                  onPressed: onDelete,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 40, minHeight: 40),
                  iconSize: 14,
                  color: colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Outlined pill that appends a new binding slot and starts recording.
class _AddKeyButton extends StatelessWidget {
  const _AddKeyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: colorScheme.outlineVariant),
    );

    return Tooltip(
      message: '添加按键',
      child: Material(
        color: Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          // 触区撑到 ~40dp：与 keycap 删除按钮同一套微操作热区标准。
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Icon(
              Icons.add_rounded,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
