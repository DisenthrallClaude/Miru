import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/appbar/sys_app_bar.dart';
import 'package:miru/bean/widget/glass_fab.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/network/proxy_utils.dart';
import 'package:miru/services/network/proxy_manager.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/request/core/network_config.dart';

class ProxyEditorPage extends StatefulWidget {
  const ProxyEditorPage({super.key});

  @override
  State<ProxyEditorPage> createState() => _ProxyEditorPageState();
}

class _ProxyEditorPageState extends State<ProxyEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController urlController = TextEditingController();
  final TextEditingController testUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    urlController.text = GStorage.getSetting(SettingsKeys.proxyUrl);
    testUrlController.text = GStorage.getSetting(SettingsKeys.proxyTestUrl);
  }

  @override
  void dispose() {
    urlController.dispose();
    testUrlController.dispose();
    super.dispose();
  }

  Future<void> saveAndTest() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final url = urlController.text.trim();
    if (url.isEmpty) {
      MiruDialog.showToast(message: '请输入代理地址');
      return;
    }

    final testUrl = testUrlController.text.trim().isEmpty
        ? 'https://www.google.com'
        : testUrlController.text.trim();

    // 记录测试前状态：测试失败时整体回滚，避免把原本可用的代理
    // （用户此前启用的另一个配置）一并改坏。
    final previousUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final previousTestUrl = GStorage.getSetting(SettingsKeys.proxyTestUrl);
    final previousEnabled = GStorage.getSetting<bool>(SettingsKeys.proxyEnable);
    final previousConfigured =
        GStorage.getSetting<bool>(SettingsKeys.proxyConfigured);

    await GStorage.putSetting(SettingsKeys.proxyUrl, url);
    await GStorage.putSetting(SettingsKeys.proxyTestUrl, testUrl);
    // 重置配置状态，等待测试结果
    await GStorage.putSetting(SettingsKeys.proxyConfigured, false);

    // 临时启用代理进行测试
    await GStorage.putSetting(SettingsKeys.proxyEnable, true);
    ProxyManager.applyProxy();

    try {
      final parsed = ProxyUtils.parseProxyUrl(url);
      if (parsed == null) {
        throw StateError('Invalid proxy URL');
      }
      final dio = DioFactory.createForConfig(
        NetworkConfig(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          proxyHost: parsed.$1,
          proxyPort: parsed.$2,
          allowBadCertificates: true,
          enableLog: false,
        ),
      );
      await dio
          .get(
            testUrl,
          )
          .timeout(const Duration(seconds: 15));
      await GStorage.putSetting(SettingsKeys.proxyConfigured, true);
      MiruDialog.showToast(message: '测试成功');
    } catch (e) {
      // 测试失败：回滚到保存前的完整状态（含此前启用的代理配置），
      // 而不是一刀切关闭——用户之前可用的工作流不应被误伤。
      await GStorage.putSetting(SettingsKeys.proxyUrl, previousUrl);
      await GStorage.putSetting(SettingsKeys.proxyTestUrl, previousTestUrl);
      await GStorage.putSetting(SettingsKeys.proxyEnable, previousEnabled);
      await GStorage.putSetting(
          SettingsKeys.proxyConfigured, previousConfigured);
      if (previousEnabled) {
        ProxyManager.applyProxy();
      } else {
        ProxyManager.clearProxy();
      }
      MiruDialog.showToast(message: '代理连接失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SysAppBar(title: Text('代理配置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: SizedBox(
            width: (MediaQuery.of(context).size.width > 800) ? 800 : null,
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: '代理地址',
                      hintText: 'http://127.0.0.1:7890',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return '请输入代理地址';
                      }
                      if (!ProxyUtils.isValidProxyUrl(value)) {
                        return '格式错误，请使用 http://host:port 格式';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: testUrlController,
                    decoration: const InputDecoration(
                      labelText: '测试地址',
                      hintText: 'https://www.google.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: GlassFab.extended(
        onTap: saveAndTest,
        icon: Icons.save_rounded,
        label: '保存并测试',
      ),
    );
  }
}
