import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/settings/settings_detail_scaffold.dart';
import 'package:miru/bean/settings/settings_list.dart';
import 'package:miru/bean/settings/theme_provider.dart';
import 'package:miru/services/fonts/custom_font_service.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/utils/theme.dart';

/// 自定义字体页（v1.6.4）。
///
/// 内置精选字体目录——默认全部未下载（不占安装包体积），用户
/// 看中哪款下载哪款，下载完成即注册即生效（FontLoader 动态注册，
/// 无需重启）。每款字体都有真实预览：字体卡片用目标 family 渲染
/// 预览文案（下载后），未下载时用风格描述代替。
class CustomFontsPage extends StatefulWidget {
  const CustomFontsPage({super.key});

  @override
  State<CustomFontsPage> createState() => _CustomFontsPageState();
}

class _CustomFontsPageState extends State<CustomFontsPage> {
  late final ThemeProvider themeProvider;

  /// id → 下载/激活进行中的状态。
  final Map<String, double> _progress = {};

  /// id → 已确认下载完成（本会话内缓存，避免反复查盘）。
  final Set<String> _downloaded = {};

  @override
  void initState() {
    super.initState();
    themeProvider = context.read<ThemeProvider>();
    _refreshDownloaded();
  }

  Future<void> _refreshDownloaded() async {
    for (final entry in CustomFontService.catalog) {
      if (await CustomFontService.instance.isDownloaded(entry.id)) {
        _downloaded.add(entry.id);
      }
    }
    if (mounted) setState(() {});
  }

  String get _activeFontId => CustomFontService.instance.activeFontId;

  Future<void> _onActivate(CustomFontEntry entry) async {
    if (_progress.containsKey(entry.id)) return; // 下载中防重复点击。
    if (_activeFontId == entry.id) {
      // 已激活 → 取消，回到系统/内置字体。
      await CustomFontService.instance.deactivate();
      _rebuildTheme();
      MiruDialog.showToast(message: '已恢复默认字体');
      return;
    }
    if (_downloaded.contains(entry.id)) {
      await CustomFontService.instance.activate(entry);
      _rebuildTheme();
      MiruDialog.showToast(message: '已应用「${entry.name}」');
      setState(() {});
      return;
    }
    // 需要下载：进度态驱动卡片 UI。
    setState(() => _progress[entry.id] = 0.0);
    try {
      await CustomFontService.instance.activate(
        entry,
        onProgress: (value) {
          if (mounted) {
            setState(() => _progress[entry.id] = value);
          }
        },
      );
      _downloaded.add(entry.id);
      _rebuildTheme();
      MiruDialog.showToast(message: '「${entry.name}」下载完成并已应用');
    } catch (e) {
      MiruLogger().w('CustomFontsPage: activate failed', error: e);
      MiruDialog.showToast(message: '字体下载失败：$e');
    } finally {
      if (mounted) {
        setState(() => _progress.remove(entry.id));
      }
    }
  }

  Future<void> _onDelete(CustomFontEntry entry) async {
    await CustomFontService.instance.deleteLocal(entry.id);
    _downloaded.remove(entry.id);
    if (CustomFontService.instance.activeFontId != entry.id) {
      // 删除的不是激活字体，主题无需重建。
      setState(() {});
      MiruDialog.showToast(message: '已删除「${entry.name}」本地文件');
      return;
    }
    // 删除的就是激活字体（deleteLocal 内部已取消激活）。
    _rebuildTheme();
    MiruDialog.showToast(message: '已删除字体并恢复默认');
  }

  void _rebuildTheme() {
    themeProvider.refreshFontFamily(notify: false);
    var dark = buildMiruTheme(
      brightness: Brightness.dark,
      fontFamily: themeProvider.currentFontFamily,
      seedColor: kDefaultSeedColor,
    );
    final oled = GStorage.getSetting(SettingsKeys.oledEnhance);
    themeProvider.setTheme(
      buildMiruTheme(
        brightness: Brightness.light,
        fontFamily: themeProvider.currentFontFamily,
        seedColor: kDefaultSeedColor,
      ),
      oled ? oledDarkTheme(dark) : dark,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsDetailScaffold(
      title: const Text('自定义字体'),
      body: SettingsList(
        maxWidth: 700,
        sections: [
          SettingsSection(
            title: Text('当前'),
            tiles: [
              SettingsTile(
                leading: Icons.check_rounded,
                title: Text(_activeTitle()),
                description: Text(_activeDescription()),
                onPressed: _activeFontId.isNotEmpty
                    ? (_) => _onActivate(_activeEntry()!)
                    : null,
              ),
            ],
            bottomInfo: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '所有字体均为免费商用授权，下载保存在本机应用目录。'
                '激活后立即生效，无需重启；「当前」一项可随时点击取消。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
              ),
            ),
          ),
          SettingsSection(
            title: Text('字体目录'),
            tiles: [
              for (final entry in CustomFontService.catalog) _fontTile(entry),
            ],
          ),
        ],
      ),
    );
  }

  CustomFontEntry? _activeEntry() {
    final id = _activeFontId;
    if (id.isEmpty) return null;
    for (final entry in CustomFontService.catalog) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  String _activeTitle() {
    final entry = _activeEntry();
    if (entry == null) {
      final usingSystem = themeProvider.currentFontFamily == null;
      return usingSystem ? '系统字体（未自定义）' : '内置思源宋体（未自定义）';
    }
    return '${entry.name} · ${entry.style}';
  }

  String _activeDescription() {
    final entry = _activeEntry();
    if (entry == null) {
      return '从下方目录选择一款字体下载并应用';
    }
    return '点击取消自定义，恢复系统/内置字体';
  }

  Widget _fontTile(CustomFontEntry entry) {
    final active = _activeFontId == entry.id;
    final downloading = _progress[entry.id];
    final downloaded = _downloaded.contains(entry.id);
    final scheme = Theme.of(context).colorScheme;

    final Widget trailing;
    if (downloading != null) {
      trailing = SizedBox(
        width: 96,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                value: downloading <= 0 ? null : downloading,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(downloading * 100).round()}%',
              style: TextStyle(
                fontSize: 12,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      );
    } else if (active) {
      trailing = Icon(Icons.check_circle_rounded, color: scheme.primary);
    } else if (downloaded) {
      // 已下载未激活：状态 + 删除入口（长按列表项不可行——SettingsTile
      // 的整行 onTap 已被「应用」占用，删除放 trailing 小图标）。
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('已下载'),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => _confirmDelete(entry),
            child: Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: scheme.outline,
            ),
          ),
        ],
      );
    } else {
      trailing = Text('${entry.sizeLabel} MB');
    }

    return SettingsTile(
      leading: Icons.font_download_outlined,
      title: Text(
        '${entry.name}  ${entry.previewText}',
        // 已下载/激活的字体：标题直接用目标 family 渲染（真字预览）。
        style: TextStyle(
          fontFamily: downloaded || active ? entry.family : null,
        ),
      ),
      description: Text(
        '${entry.style} · ${entry.license} · ${entry.sizeLabel} MB'
        '${entry.weights.length > 1 ? ' · ${entry.weights.length} 个字重' : ''}',
      ),
      trailing: trailing,
      enabled: downloading == null,
      onPressed: (_) => _onActivate(entry),
    );
  }

  Future<void> _confirmDelete(CustomFontEntry entry) async {
    final confirmed = await MiruDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: Text('删除字体'),
        content: Text('确定删除「${entry.name}」的本地字体文件？'
            '删除后可重新下载。'),
        actions: [
          TextButton(
            onPressed: () => MiruDialog.dismiss(popWith: false),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () => MiruDialog.dismiss(popWith: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _onDelete(entry);
    }
  }
}
