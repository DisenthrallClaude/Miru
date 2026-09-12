// 白猫(baimao v2.0)与 fqdm(v2.0) 规则聚焦实测
// 运行: flutter test test/live_baimao_fqdm_test.dart -r expanded
//（需临时移开 dart_test.yaml 的 live skip 配置，或 --tags live 环境下执行）
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

  // 整个文件只初始化一次（重复 init 会二次注册 Hive TypeAdapter）。
  setUpAll(() async {
    await Hive.initFlutter('/tmp/miru_live_test/hive');
    await GStorage.init();
  });

  Plugin loadPlugin(String path) {
    final json = jsonDecode(File(path).readAsStringSync())
        as Map<String, dynamic>;
    return Plugin.fromJson(json);
  }

  test('baimao v2.0 live validation', () async {
    final plugin = loadPlugin('assets/plugins/baimao.json');

    // 搜索
    final trace =
        await plugin.traceSearch('斗破苍穹').timeout(const Duration(seconds: 30));
    // ignore: avoid_print
    print('搜索结果数: ${trace.response.data.length}');
    // ignore: avoid_print
    print('样本: ${trace.response.data.take(3).map((e) => e.name).toList()}');
    expect(trace.response.data, isNotEmpty,
        reason: '白猫搜索应返回结果（新域名 bmmdmm.com）');

    // 章节：优先选「第三季」（有完整资源）；注意部分番（如年番2）
    // 站点侧标注「暂无播放资源」，属站点内容状态而非规则缺陷。
    final target = trace.response.data.firstWhere(
      (e) => e.name.contains('第三季'),
      orElse: () => trace.response.data.first,
    );
    // ignore: avoid_print
    print('选集目标: 《${target.name}》 ${target.src}');
    final chapterTrace = await plugin
        .traceChapters(target.src)
        .timeout(const Duration(seconds: 30));
    final roads = chapterTrace.roads;
    // ignore: avoid_print
    print('线路数: ${roads.length}, '
        '总集数: ${roads.fold<int>(0, (s, r) => s + r.data.length)}');
    for (final road in roads.take(3)) {
      // ignore: avoid_print
      print('  ${road.name}: ${road.data.length} 集, '
          '首集 ${road.data.first}');
    }
    expect(roads, isNotEmpty, reason: '白猫选集应解析出播放线路');
    expect(roads.fold<int>(0, (s, r) => s + r.data.length), greaterThan(0),
        reason: '线路内应有剧集');
    expect(roads.first.data.first, contains('/play/'),
        reason: '剧集链接应为站内播放页路径');

    // 「暂无播放资源」的番（年番2）：解析为空线路是诚实的站点状态，
    // 不应抛出规则级异常之外的崩溃——验证其可被正常捕获。
    final emptyTarget = trace.response.data
        .where((e) => e.name.contains('年番2'))
        .firstOrNull;
    if (emptyTarget != null) {
      try {
        await plugin.traceChapters(emptyTarget.src);
      } catch (e) {
        // ignore: avoid_print
        print('年番2（站点无资源）按预期报 ChapterError: ${e.runtimeType}');
        expect(e.runtimeType.toString(), contains('ChapterError'));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('fqdm v2.0 live validation', () async {
    final plugin = loadPlugin('assets/plugins/fqdm.json');

    final trace =
        await plugin.traceSearch('斗破苍穹').timeout(const Duration(seconds: 30));
    // ignore: avoid_print
    print('fqdm 搜索结果数: ${trace.response.data.length}');
    // ignore: avoid_print
    print('样本: ${trace.response.data.take(3).map((e) => e.name).toList()}');
    expect(trace.response.data, isNotEmpty, reason: 'fqdm 搜索应返回结果');

    final target = trace.response.data.first;
    final chapterTrace = await plugin
        .traceChapters(target.src)
        .timeout(const Duration(seconds: 30));
    // ignore: avoid_print
    print('fqdm 《${target.name}》线路数: ${chapterTrace.roads.length}, '
        '总集数: ${chapterTrace.roads.fold<int>(0, (s, r) => s + r.data.length)}');
    expect(chapterTrace.roads, isNotEmpty, reason: 'fqdm 选集应解析出线路');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
