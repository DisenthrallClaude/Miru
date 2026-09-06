import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/secure_field_codec.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/sync/github_api.dart';
import 'package:miru/services/sync/github_sync.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// GitHub 应用内登录面板（v1.6.4）。
///
/// 「通过 GitHub 进入」此前直接跳外部浏览器打开仓库页——用户
/// 离开了应用。现在改为应用内完成整个登录动作：
/// 1. 「生成令牌」在应用内浏览器视图（Custom Tabs / SFSafari）
///    打开 GitHub 的 PAT 创建页，用户登录 GitHub、勾权限、生成；
/// 2. 回到面板粘贴令牌，验证通过即完成登录（自动建同步仓库）；
/// 3. 登录成功后由调用方决定后续（开屏页 = 进入主界面并开同步）。
///
/// 已登录用户直接显示账号状态并提供「继续」动作。
class GithubLoginSheet extends StatefulWidget {
  const GithubLoginSheet({super.key, this.onSuccess});

  /// 登录成功（或已登录直接继续）后回调。
  final VoidCallback? onSuccess;

  @override
  State<GithubLoginSheet> createState() => _GithubLoginSheetState();
}

class _GithubLoginSheetState extends State<GithubLoginSheet> {
  final TextEditingController _tokenController = TextEditingController();
  bool _verifying = false;
  bool _tokenVisible = false;

  static const _tokenPageUrl =
      'https://github.com/settings/personal-access-tokens/new';

  bool get _loggedIn =>
      GStorage.getSetting(SettingsKeys.githubEnable) &&
      GStorage.getSetting(SettingsKeys.githubLogin).isNotEmpty;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _openTokenPage() async {
    try {
      // 应用内浏览器视图：不离开应用；不支持时回退外部浏览器。
      await launchUrlString(
        _tokenPageUrl,
        mode: LaunchMode.inAppBrowserView,
        browserConfiguration: const BrowserConfiguration(
          showTitle: true,
        ),
      );
    } catch (_) {
      try {
        await launchUrlString(
          _tokenPageUrl,
          mode: LaunchMode.externalApplication,
        );
      } catch (e) {
        MiruLogger().w('GithubLoginSheet: failed to open token page', error: e);
        MiruDialog.showToast(message: '无法打开 GitHub，请检查网络');
      }
    }
  }

  Future<void> _login() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      MiruDialog.showToast(message: '请先粘贴 Personal Access Token');
      return;
    }
    if (_verifying) return;
    setState(() => _verifying = true);
    try {
      final encrypted = await SecureFieldCodec.encrypt(token);
      await GStorage.putSetting(SettingsKeys.githubToken, encrypted);
      final repoName = await GithubSync().loginAndEnsureRepo();
      if (!mounted) return;
      MiruDialog.showToast(message: '已登录 GitHub，同步仓库 $repoName');
      Navigator.of(context).pop(true);
      widget.onSuccess?.call();
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final login = GStorage.getSetting(SettingsKeys.githubLogin);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync_outlined,
                    color: scheme.primary, size: 22),
                const SizedBox(width: 8),
                Text(
                  '通过 GitHub 登录',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _loggedIn
                  ? '已登录为 $login。云端同步（观看历史 / 追番收藏）已就绪，'
                      '继续即可进入。'
                  : '登录后开启云端同步：观看历史与追番收藏跨设备备份，'
                      '重装 / 换机不丢数据。GitHub 已关闭账号密码直登通道，'
                      '合规方式是生成一枚 Personal Access Token 粘贴到下方——'
                      '全程在应用内完成。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            if (_loggedIn) ...[
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop(true);
                  widget.onSuccess?.call();
                },
                icon: const Icon(Icons.login_rounded),
                label: const Text('继续进入'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  '返回',
                  style: TextStyle(color: scheme.outline),
                ),
              ),
            ] else ...[
              // 步骤 1：应用内生成令牌。
              OutlinedButton.icon(
                onPressed: _openTokenPage,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('第 1 步 · 在应用内打开 GitHub 生成令牌'),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '生成页权限建议：Repository access 选 Only select '
                  'repositories；Permissions 勾 Contents → Read and write。'
                  '生成后长按令牌复制，回到这里粘贴。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                        height: 1.5,
                      ),
                ),
              ),
              // 步骤 2：粘贴令牌。
              TextField(
                controller: _tokenController,
                obscureText: !_tokenVisible,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: '第 2 步 · 粘贴令牌',
                  hintText: 'github_pat_… 或 ghp_…',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key_rounded),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '从剪贴板粘贴',
                        onPressed: () async {
                          final data = await Clipboard.getData('text/plain');
                          final text = data?.text?.trim() ?? '';
                          if (text.isNotEmpty) {
                            _tokenController.text = text;
                          } else {
                            MiruDialog.showToast(message: '剪贴板为空');
                          }
                        },
                        icon: const Icon(Icons.content_paste_rounded),
                      ),
                      IconButton(
                        tooltip: _tokenVisible ? '隐藏' : '显示',
                        onPressed: () => setState(
                            () => _tokenVisible = !_tokenVisible),
                        icon: Icon(_tokenVisible
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _verifying ? null : _login,
                icon: _verifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login_rounded),
                label: Text(_verifying ? '验证中…' : '登录并进入'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  '暂不登录，直接进入',
                  style: TextStyle(color: scheme.outline),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 弹出 GitHub 应用内登录面板。
///
/// 返回 true = 已登录（或登录成功）；false = 用户取消。
Future<bool> showGithubLoginSheet(
  BuildContext context, {
  VoidCallback? onSuccess,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: GithubLoginSheet(onSuccess: onSuccess),
    ),
  );
  return result ?? false;
}
