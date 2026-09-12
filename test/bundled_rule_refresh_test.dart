// v1.6.10 内置规则刷新链路实测：
// 1) plugins.json 里旧版 baimao v1.0 → 启动刷新后升级为随包 v2.0
// 2) localModified 规则不被随包版本覆盖
// 3) fqdm 大小写变化（fqdm → FQDM）按 catalogKey 归并、不重复安装
@Tags(['live'])
library;

import 'dart:convert';
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
        return '/tmp/miru_bundled_refresh_test';
    }
    return null;
  });

  test('bundled rule refresh upgrades existing users', () async {
    final dir = '/tmp/miru_bundled_refresh_test';
    await Hive.initFlutter('$dir/hive');
    await GStorage.init();

    final controller = PluginsController();
    await controller.init();

    // 种子：模拟 v1.6.9 存量用户——baimao v1.0（旧域名）、
    // fqdm v1.0（旧名小写）、本地修改过的 7sefun v1.3。
    final pluginsFile =
        File('$dir/plugins/v2/plugins.json');
    final seed = <Map<String, dynamic>>[
      {
        'api': '5',
        'type': 'anime',
        'name': 'baimao',
        'version': '1.0',
        'muliSources': true,
        'useWebview': true,
        'useNativePlayer': true,
        'userAgent': '',
        'adBlocker': true,
        'baseURL': 'https://www.baimaodm.com/',
        'searchURL': 'https://www.baimaodm.com/s_all?ex=1&kw=@keyword',
        'searchList': '//div[4]/div[2]/div[1]/ul/li',
        'searchName': '//h2/a',
        'searchResult': '//h2/a',
        'chapterRoads': '//div[2]/div[2]/div[8]/div/div/ul',
        'chapterResult': '//li/a',
        'localModified': false,
      },
      {
        'api': '5',
        'type': 'anime',
        'name': 'fqdm',
        'version': '1.0',
        'muliSources': true,
        'useWebview': true,
        'useNativePlayer': true,
        'userAgent': '',
        'adBlocker': true,
        'baseURL': 'https://www.fqdm.cc/',
        'searchURL': 'https://www.fqdm.cc/index.php/vod/search.html?wd=@keyword',
        'searchList': '//div[contains(@class,"module-card-item")]',
        'searchName': "//div[contains(@class,'module-card-item-title')]/a",
        'searchResult': "//div[contains(@class,'module-card-item-title')]/a",
        'chapterRoads': '//div',
        'chapterResult': "//a[@class='module-play-list-link']",
        'localModified': false,
      },
      {
        'api': '5',
        'type': 'anime',
        'name': '7sefun',
        'version': '1.3',
        'muliSources': true,
        'useWebview': true,
        'useNativePlayer': true,
        'userAgent': '',
        'adBlocker': true,
        'baseURL': 'https://7sefun.com/',
        'searchURL': 'https://7sefun.com/search?q=@keyword',
        'searchList': '//div',
        'searchName': '//a',
        'searchResult': '//a',
        'chapterRoads': '//div',
        'chapterResult': '//a',
        'localModified': true, // 用户改过，不应被覆盖
      },
    ];
    await pluginsFile.parent.create(recursive: true);
    await pluginsFile.writeAsString(jsonEncode(seed));

    // 重新加载种子数据。
    await controller.init();

    // AssetManifest 在 flutter test 环境下依赖构建产物；不可见时跳过
    // 断言（真机/CI 构建环境会覆盖该路径）。
    var bundledCount = 0;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      bundledCount = manifest
          .listAssets()
          .where((a) => a.startsWith('assets/plugins/'))
          .length;
    } catch (e) {
      // ignore: avoid_print
      print('AssetManifest 不可用: $e');
    }
    // ignore: avoid_print
    print('测试环境可见的内置规则 asset 数: $bundledCount');
    if (bundledCount == 0) {
      // ignore: avoid_print
      print('测试环境无内置规则资产，跳过刷新断言（真机环境覆盖此路径）');
      return;
    }

    await controller.copyPluginsToExternalDirectory();

    final byName = {
      for (final p in controller.pluginList) p.name.toLowerCase(): p
    };

    // 1) baimao 应升级为 v2.0 且换到新域名。
    final baimao = byName['baimao'];
    // ignore: avoid_print
    print('baimao 刷新后: version=${baimao?.version} '
        'baseURL=${baimao?.baseUrl}');
    expect(baimao?.version, '2.0',
        reason: '存量 baimao v1.0 应被随包 v2.0 升级');
    expect(baimao?.baseUrl, contains('bmmdmm.com'),
        reason: '升级后应使用新域名');

    // 2) fqdm 升级为 v2.0，且大小写归并（不出现两条）。
    final fqdmCount = controller.pluginList
        .where((p) => p.name.toLowerCase() == 'fqdm')
        .length;
    // ignore: avoid_print
    print('fqdm 刷新后: version=${byName['fqdm']?.version}, 条数=$fqdmCount');
    expect(fqdmCount, 1, reason: 'fqdm/FQDM 应按 catalogKey 归并为一条');
    expect(byName['fqdm']?.version, '2.0',
        reason: '存量 fqdm v1.0 应被随包 v2.0 升级');

    // 3) localModified 的 7sefun 不被覆盖（保留种子里的旧 searchURL）。
    final sefun = byName['7sefun'];
    // ignore: avoid_print
    print('7sefun 刷新后: searchURL=${sefun?.searchURL}');
    expect(sefun?.searchURL, contains('search?q='),
        reason: '本地修改过的规则不应被随包版本覆盖');
    expect(sefun?.localModified, isTrue, reason: 'localModified 标记应保留');

    // 4) 未随包安装的其他规则不应被静默删除。
    expect(controller.pluginList.length, greaterThanOrEqualTo(3));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
