// 内置规则逐一实测(真实 RuleEngine + 真实网络请求)
//
// 运行: flutter test test/live_rule_validation_test.dart --plain-name "live rule validation" -r expanded
// 输出: 每条规则的 搜索结果数 / 线路数 / 集数 / 首个剧集URL
//
// 与 app 完全同栈: Dart html parser + xpath_selector + dio,
// 结论可直接作为「内置规则去留」的依据。
//
// 标记 live: 依赖真实网络且耗时数分钟，日常回归用
// `flutter test --exclude-tags live` 跳过本文件。
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/plugins/plugins.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 会在 binding 初始化时安装 HttpOverrides.global =
  // _MockHttpOverrides(所有 HttpClient 一律返回 400, 见
  // flutter_test/lib/src/_binding_io.dart)。本测试需要真实网络访问
  // 规则站点, 这里显式清掉该 override, 恢复真实 HttpClient。
  // (只影响本测试文件自身的进程。)
  HttpOverrides.global = null;

  // mock path_provider, 让 GStorage.init 在测试环境可用
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

  // app 在真机上从 rootBundle 读规则; 测试环境里 assets 已注册,
  // 但 flutter test 加载 asset 需要 AssetManifest —— 直接用文件读更稳。
  final dir = Directory('assets/plugins');
  test('live rule validation', () async {
    await Hive.initFlutter('/tmp/miru_live_test/hive');
    await GStorage.init();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final report = <String, Map<String, dynamic>>{};
    final keyword = '斗破苍穹';

    for (final file in files) {
      final name = file.path.split('/').last;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (e) {
        report[name] = {'error': 'json 解析失败: $e'};
        continue;
      }
      final plugin = Plugin.fromJson(json);
      final row = <String, dynamic>{};
      try {
        final trace = await plugin.traceSearch(keyword)
            .timeout(const Duration(seconds: 30));
        final items = trace.response.data;
        row['searchItems'] = items.length;
        row['sample'] =
            items.take(3).map((e) => e.name).toList(growable: false);
        if (items.isNotEmpty) {
          final target = items.firstWhere(
            (e) => e.name.contains(keyword),
            orElse: () => items.first,
          );
          final chapterTrace = await plugin
              .traceChapters(target.src)
              .timeout(const Duration(seconds: 30));
          final roads = chapterTrace.roads;
          row['roads'] = roads.length;
          row['episodes'] =
              roads.fold<int>(0, (sum, r) => sum + r.data.length);
          if (roads.isNotEmpty && roads.first.data.isNotEmpty) {
            row['firstEpisodeUrl'] = roads.first.data.first;
          }
        }
      } catch (e) {
        row['error'] = e.toString().split('\n').first;
      }
      report[name] = row;
      // ignore: avoid_print
      print('=== $name: ${jsonEncode(row)}');
    }

    // ignore: avoid_print
    print('FULL_REPORT_BEGIN');
    // ignore: avoid_print
    print(jsonEncode(report));
    // ignore: avoid_print
    print('FULL_REPORT_END');
    expect(report.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
