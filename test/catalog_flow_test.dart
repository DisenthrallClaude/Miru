// 后端链路复扫: 规则仓库目录拉取 + 单条规则安装 (真实网络)
// 验证 api_endpoints.dart 指向 KazumiRules 后的完整目录流程无回归。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/services/storage/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        return '/tmp/miru_live_test';
    }
    return null;
  });

  test('rule catalog fetch and install flow', () async {
    await Hive.initFlutter('/tmp/miru_live_test/hive5');
    await GStorage.init();

    final controller = PluginsController();
    await controller.init();

    // 1. 目录拉取 (走 rulesRepoDio, 默认无镜像时直连 GitHub)
    final catalog = await controller.refreshPluginCatalog();
    // ignore: avoid_print
    print('目录条目数: ${catalog.length}');
    expect(catalog.isNotEmpty, isTrue, reason: '规则目录不能为空');

    // 2. 目录里应包含日漫规则(供手动安装)与国漫规则
    final names = catalog.map((e) => e.name).toSet();
    // ignore: avoid_print
    print('目录规则: ${names.toList().join(', ')}');
    expect(names.contains('aafun'), isTrue, reason: '日漫规则应保留在目录中供手动安装');

    // 3. 单条规则安装: 取一条当前未内置的日漫规则走完整下载+解析
    final result = await controller.tryUpdatePluginByName('aafun');
    // ignore: avoid_print
    print('aafun 安装结果: $result');
    expect(result, PluginUpdateResult.updated, reason: '规则应可从仓库正常安装');

    // 4. 安装后应出现在插件列表
    expect(controller.pluginList.any((p) => p.name == 'aafun'), isTrue);

    // 5. 删除规则
    await controller.removePlugins({'aafun'});
    expect(controller.pluginList.any((p) => p.name == 'aafun'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
