import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/storage/secure_field_codec.dart';
import 'package:miru/bean/appbar/sys_app_bar.dart';
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
  final TextEditingController webDavURLController = TextEditingController();
  final TextEditingController webDavUsernameController =
      TextEditingController();
  final TextEditingController webDavPasswordController =
      TextEditingController();
  bool passwordVisible = false;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SysAppBar(
        title: Text('WEBDAV编辑'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: SizedBox(
            width: (MediaQuery.of(context).size.width > 1000) ? 1000 : null,
            child: Column(
              children: [
                TextField(
                  controller: webDavURLController,
                  decoration: const InputDecoration(
                      labelText: 'URL', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: webDavUsernameController,
                  decoration: const InputDecoration(
                      labelText: 'Username', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: webDavPasswordController,
                  obscureText: !passwordVisible,
                  decoration: InputDecoration(
                    labelText: 'Password',
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
                // const SizedBox(height: 20),
                // ExpansionTile(
                //   title: const Text('高级选项'),
                //   children: [],
                // ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.save),
        onPressed: () async {
          GStorage.putSetting(SettingsKeys.webDavURL, webDavURLController.text);
          GStorage.putSetting(
              SettingsKeys.webDavUsername, webDavUsernameController.text);
          // 密码先经 Android Keystore 加密再落盘，避免明文存储；
          // 平台不支持时 SecureFieldCodec 会降级为明文，保存不会失败。
          final encryptedPassword = await SecureFieldCodec.encrypt(
              webDavPasswordController.text);
          await GStorage.putSetting(
              SettingsKeys.webDavPassword, encryptedPassword);
          var webDav = WebDav();
          try {
            await webDav.init();
          } catch (e) {
            MiruDialog.showToast(message: '配置失败 ${e.toString()}');
            await GStorage.putSetting(SettingsKeys.webDavEnable, false);
            return;
          }
          MiruDialog.showToast(message: '配置成功, 开始测试');
          try {
            await webDav.ping();
            MiruDialog.showToast(message: '测试成功');
          } catch (e) {
            MiruDialog.showToast(message: '测试失败 ${e.toString()}');
            await GStorage.putSetting(SettingsKeys.webDavEnable, false);
          }
        },
      ),
    );
  }
}
