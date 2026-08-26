import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/settings/settings_detail_scaffold.dart';
import 'package:miru/bean/settings/settings_list.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/secure_field_codec.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/sync/github_api.dart';
import 'package:miru/services/sync/github_sync.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub 登录与云同步设置页。
///
/// 认证方式如实说明：GitHub 已于 2020/2021 年彻底关闭第三方
/// 「账号 + 密码」直登通道，全球所有第三方应用都只剩两条合规路径：
/// OAuth 授权跳转或 Personal Access Token。本页采用 PAT 方案——
/// 用户在 GitHub 网页生成令牌粘贴进来，权限可以收敛到单个私有仓库。
class GithubSettingsPage extends StatefulWidget {
  const GithubSettingsPage({super.key});

  @override
  State<GithubSettingsPage> createState() => _GithubSettingsPageState();
}

class _GithubSettingsPageState extends State<GithubSettingsPage> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _repoController = TextEditingController();

  bool _tokenVisible = false;
  bool _verifying = false;
  bool _syncing = false;
  bool _historyEnabled = false;
  bool _collectEnabled = false;

  @override
  void initState() {
    super.initState();
    _historyEnabled = GStorage.getSetting(SettingsKeys.githubEnableHistory);
    _collectEnabled = GStorage.getSetting(SettingsKeys.githubEnableCollect);
    _loadStoredCredentials();
  }

  Future<void> _loadStoredCredentials() async {
    final storedToken = GStorage.getSetting(SettingsKeys.githubToken);
    if (storedToken.isNotEmpty) {
      final plain = await SecureFieldCodec.decrypt(storedToken);
      if (mounted && plain != null) {
        _tokenController.text = plain;
      }
    }
    final repo = GStorage.getSetting(SettingsKeys.githubRepo);
    _repoController.text = repo.isEmpty ? '' : repo.split('/').last;
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _repoController.dispose();
    super.dispose();
  }

  bool get _loggedIn =>
      GStorage.getSetting(SettingsKeys.githubEnable) &&
      GStorage.getSetting(SettingsKeys.githubLogin).isNotEmpty;

  Future<void> _login() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      MiruDialog.showToast(message: '请先粘贴 Personal Access Token');
      return;
    }
    setState(() => _verifying = true);
    try {
      // 先落盘（加密），登录流程会读取。
      final encrypted = await SecureFieldCodec.encrypt(token);
      await GStorage.putSetting(SettingsKeys.githubToken, encrypted);
      final repoName = await GithubSync().loginAndEnsureRepo(
        repoName: _repoController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() {});
      MiruDialog.showToast(message: '已登录，同步仓库 $repoName');
    } catch (e) {
      await GStorage.putSetting(SettingsKeys.githubEnable, false);
      if (mounted) {
        MiruDialog.showToast(message: '登录失败：${describeGithubError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _logout() async {
    await GithubSync().logout();
    if (!mounted) {
      return;
    }
    setState(() {
      _tokenController.clear();
    });
    MiruDialog.showToast(message: '已退出登录，本地数据完整保留');
  }

  Future<void> _syncNow() async {
    final sync = GithubSync();
    if (!_loggedIn) {
      MiruDialog.showToast(message: '请先登录');
      return;
    }
    setState(() => _syncing = true);
    try {
      if (!sync.initialized) {
        await sync.init();
      }
      final messages = <String>[];
      if (GStorage.getSetting(SettingsKeys.githubEnableHistory)) {
        try {
          await sync.syncHistory();
          messages.add('历史完成');
        } catch (e) {
          messages.add('历史失败：${describeGithubError(e)}');
        }
      }
      if (GStorage.getSetting(SettingsKeys.githubEnableCollect)) {
        try {
          await sync.syncCollectibles();
          messages.add('收藏完成');
        } catch (e) {
          messages.add('收藏失败：${describeGithubError(e)}');
        }
      }
      if (messages.isEmpty) {
        messages.add('所有同步开关均已关闭');
      }
      if (mounted) {
        setState(() {});
        MiruDialog.showToast(message: messages.join('；'));
      }
    } catch (e) {
      if (mounted) {
        MiruDialog.showToast(message: describeGithubError(e));
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  Future<void> _openTokenPage() async {
    final url = Uri.parse(
      'https://github.com/settings/personal-access-tokens/new',
    );
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      MiruLogger().w('GithubSettings: failed to open token page', error: e);
      MiruDialog.showToast(
          message: '无法打开浏览器，请手动访问 github.com/settings/tokens');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('GITHUB 云同步'),
      body: SettingsList(
        maxWidth: 700,
        sections: [
          SettingsSection(tiles: [_accountTile()]),
          if (!_loggedIn) ..._loginSections() else ..._syncSections(),
        ],
      ),
    );
  }

  Widget _accountTile() {
    final loggedIn = _loggedIn;
    final login = GStorage.getSetting(SettingsKeys.githubLogin);
    final repo = GStorage.getSetting(SettingsKeys.githubRepo);

    return SettingsTile(
      leading: Icons.account_circle_rounded,
      title: Text(loggedIn ? login : '未登录'),
      description: Text(
        loggedIn ? repo : '本地模式 · 数据仅存本机，登录后可云端备份',
      ),
      trailing: loggedIn
          ? TextButton(
              onPressed: _logout,
              child: const Text('退出登录'),
            )
          : null,
      onPressed: loggedIn ? null : (_) => _focusTokenInput(),
    );
  }

  void _focusTokenInput() {
    // 输入卡片就在下方，滚动交给用户；这里只做轻提示。
    MiruDialog.showToast(message: '在下方粘贴 Token 完成登录');
  }

  List<Widget> _loginSections() {
    final theme = Theme.of(context);
    return [
      SettingsSection(
        title: Text('登录'),
        bottomInfo: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '为什么不能用账号密码登录：GitHub 自 2020 年 11 月起关闭 API 密码认证，'
            '2021 年 8 月起移除 Git 密码通道，此后所有第三方应用只剩 OAuth 网页授权'
            '或 Personal Access Token 两种合规方式。任何声称「只输账号密码」的实现'
            '都是模拟登录页的爬虫，违反 GitHub 条款且有账号风险，本应用不提供。\n'
            'Token 权限建议（fine-grained）：Repository access 选 Only select '
            'repositories；Permissions 勾 Contents → Read and write。'
            '如需自动建仓再勾 Administration，否则可手动在网页建仓。\n'
            '若你已配置 WebDAV（设置 → 同步设置），同样能解决重装丢数据的问题，'
            'GitHub 方案只是免自备网盘的便利层。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
        tiles: [
          _tokenFieldTile(),
          _repoFieldTile(),
          SettingsTile(
            leading: Icons.open_in_new_rounded,
            title: const Text('前往 GitHub 生成 Token'),
            description:
                const Text('github.com/settings/personal-access-tokens'),
            onPressed: (_) => _openTokenPage(),
          ),
          SettingsTile(
            leading: Icons.login_rounded,
            title: Text(_verifying ? '验证中…' : '验证并登录'),
            description: const Text('验证 Token 并确保私有同步仓库存在（缺失时自动创建）'),
            enabled: !_verifying,
            onPressed: (_) => _login(),
          ),
        ],
      ),
    ];
  }

  Widget _tokenFieldTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: _tokenController,
        obscureText: !_tokenVisible,
        decoration: InputDecoration(
          labelText: 'Personal Access Token',
          hintText: 'github_pat_… 或 ghp_…',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
            icon: Icon(_tokenVisible
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded),
          ),
        ),
      ),
    );
  }

  Widget _repoFieldTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: _repoController,
        decoration: const InputDecoration(
          labelText: '同步仓库名（可选）',
          hintText: 'miru-sync',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  List<Widget> _syncSections() {
    return [
      SettingsSection(
        title: const Text('同步内容'),
        tiles: [
          SettingsTile.switchTile(
            leading: Icons.history_rounded,
            title: const Text('同步观看历史'),
            description: const Text('重装或换机后恢复播放进度'),
            initialValue: _historyEnabled,
            onToggle: (value) async {
              _historyEnabled = value ?? !_historyEnabled;
              await GStorage.putSetting(
                  SettingsKeys.githubEnableHistory, _historyEnabled);
              setState(() {});
            },
          ),
          SettingsTile.switchTile(
            leading: Icons.favorite_rounded,
            title: const Text('同步追番收藏'),
            description: const Text('收藏分组与变更记录双向合并'),
            initialValue: _collectEnabled,
            onToggle: (value) async {
              _collectEnabled = value ?? !_collectEnabled;
              await GStorage.putSetting(
                  SettingsKeys.githubEnableCollect, _collectEnabled);
              setState(() {});
            },
          ),
        ],
      ),
      SettingsSection(
        title: const Text('操作'),
        tiles: [
          SettingsTile(
            leading: Icons.sync_rounded,
            title: Text(_syncing ? '同步中…' : '立即同步'),
            description: Text(_lastSyncLine()),
            enabled: !_syncing,
            onPressed: (_) => _syncNow(),
          ),
        ],
      ),
    ];
  }

  String _lastSyncLine() {
    final last = GStorage.getSetting(SettingsKeys.githubLastSyncTime);
    if (last <= 0) {
      return '尚未同步过；启动与退出播放器时会自动同步';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(last);
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次同步 ${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}；启动与退出播放器时会自动同步';
  }
}
