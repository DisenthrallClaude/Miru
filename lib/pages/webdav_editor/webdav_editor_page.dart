import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/storage/secure_field_codec.dart';
import 'package:miru/bean/appbar/sys_app_bar.dart';
import 'package:miru/bean/widget/glass_fab.dart';
import 'package:miru/services/sync/webdav.dart';
import 'package:miru/services/logging/logger.dart';

class WebDavEditorPage extends StatefulWidget {
  const WebDavEditorPage({
    super.key,
  });

  @override
  State<WebDavEditorPage> createState() => _WebDavEditorPageState();
}

class _WebDavEditorPageState extends State<WebDavEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController webDavURLController = TextEditingController();
  final TextEditingController webDavUsernameController =
      TextEditingController();
  final TextEditingController webDavPasswordController =
      TextEditingController();
  bool passwordVisible = false;

  /// 保存/测试进行中：FAB 禁用防连点（测试最长 10s+ 超时，
  /// 期间并发触发会同时跑多轮 init/ping）。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    webDavURLController.text = GStorage.getSetting(SettingsKeys.webDavURL);
    webDavUsernameController.text =
        GStorage.getSetting(SettingsKeys.webDavUsername);
    _loadStoredPassword();
  }

  /// 存储中的密码是 Keystore 密文，进入页面时解密回显明文；
  /// 解密失败说明密钥已丢失，清空输入框让用户重新输入。
  Future<void> _loadStoredPassword() async {
    final storedPassword = GStorage.getSetting(SettingsKeys.webDavPassword);
    if (storedPassword.isEmpty) {
      return;
    }
    final password = await SecureFieldCodec.decrypt(storedPassword);
    if (!mounted) {
      return;
    }
    if (password == null) {
      MiruLogger().e('WebDavEditor: stored password cannot be decrypted');
      MiruDialog.showToast(message: '密码无法解密，请重新输入');
      return;
    }
    webDavPasswordController.text = password;
  }

  @override
  void dispose() {
    webDavURLController.dispose();
    webDavUsernameController.dispose();
    webDavPasswordController.dispose();
    super.dispose();
  }

  /// 保存并测试。失败时按代理编辑器同款「整体回滚」策略：
  /// 凭据不留在存储里、同步开关还原，避免半保存状态。
  Future<void> _saveAndTest() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;

    final previousURL = GStorage.getSetting(SettingsKeys.webDavURL);
    final previousUsername =
        GStorage.getSetting(SettingsKeys.webDavUsername);
    final previousPassword =
        GStorage.getSetting(SettingsKeys.webDavPassword);
    final previousEnable =
        GStorage.getSetting<bool>(SettingsKeys.webDavEnable);

    setState(() => _saving = true);
    try {
      GStorage.putSetting(
          SettingsKeys.webDavURL, webDavURLController.text.trim());
      GStorage.putSetting(SettingsKeys.webDavUsername,
          webDavUsernameController.text.trim());
      // 密码先经 Android Keystore 加密再落盘，避免明文存储；
      // 平台不支持时 SecureFieldCodec 会降级为明文，保存不会失败。
      final encryptedPassword = await SecureFieldCodec.encrypt(
          webDavPasswordController.text);
      await GStorage.putSetting(
          SettingsKeys.webDavPassword, encryptedPassword);

      final webDav = WebDav();
      try {
        await webDav.init();
      } catch (e) {
        MiruLogger().w('WebDavEditor: init failed', error: e);
        MiruDialog.showToast(message: '配置失败：无法连接 WebDAV 服务器，请检查地址与账号');
        await _rollback(
            previousURL, previousUsername, previousPassword, previousEnable);
        return;
      }
      MiruDialog.showToast(message: '配置成功，开始测试');
      try {
        await webDav.ping();
        MiruDialog.showToast(message: '测试成功');
      } catch (e) {
        MiruLogger().w('WebDavEditor: ping failed', error: e);
        MiruDialog.showToast(message: '测试失败：服务器可达但响应异常，请检查 WebDAV 权限');
        await _rollback(
            previousURL, previousUsername, previousPassword, previousEnable);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 回滚到保存前的完整状态（含此前启用与否），不留半保存凭据。
  Future<void> _rollback(String url, String username, String password,
      bool enable) async {
    await GStorage.putSetting(SettingsKeys.webDavURL, url);
    await GStorage.putSetting(SettingsKeys.webDavUsername, username);
    await GStorage.putSetting(SettingsKeys.webDavPassword, password);
    await GStorage.putSetting(SettingsKeys.webDavEnable, enable);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 与设置页入口 tile「WebDAV配置」统一名称，专有品牌大小写为 WebDAV。
      appBar: const SysAppBar(
        title: Text('WebDAV 配置'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: SizedBox(
            width: (MediaQuery.of(context).size.width > 1000) ? 1000 : null,
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  // 提交前校验：此前空 URL 也直接落盘，靠 WebDav.init()
                  // 抛原始异常兜底，用户看到的是一堆英文堆栈信息。
                  TextFormField(
                    controller: webDavURLController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'https://dav.example.com/dav',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final trimmed = value?.trim() ?? '';
                      if (trimmed.isEmpty) {
                        return '请输入 WebDAV 服务器地址';
                      }
                      final uri = Uri.tryParse(trimmed);
                      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                        return '请输入完整地址（含 https:// 与主机名）';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: webDavUsernameController,
                    decoration: const InputDecoration(
                        labelText: '用户名', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: webDavPasswordController,
                    obscureText: !passwordVisible,
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            passwordVisible = !passwordVisible;
                          });
                        },
                        icon: Icon(passwordVisible
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: GlassFab.extended(
        onTap: _saving ? null : _saveAndTest,
        enabled: !_saving,
        icon: _saving
            ? Icons.hourglass_top_rounded
            : Icons.save_rounded,
        label: _saving ? '测试中…' : '保存并测试',
      ),
    );
  }
}
