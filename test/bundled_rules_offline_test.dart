// v1.7.0：内置规则离线校验——全部 assets/plugins/*.json 可被
// Plugin.fromJson 解析，且关键字段非空（防上游同步进来的坏规则
// 随包分发）。在线可达性由 live_rule_validation_test 覆盖（--tags live）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/plugins/plugins.dart';

void main() {
  final dir = Directory('assets/plugins');
  test('全部内置规则可解析且字段完整', () {
    expect(dir.existsSync(), isTrue);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(files.length, greaterThanOrEqualTo(15),
        reason: 'v1.7.0 起应含 15 条内置规则（含 LMM）');
    final names = <String>[];
    for (final file in files) {
      final plugin =
          Plugin.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      expect(plugin.name.isNotEmpty, isTrue, reason: '${file.path} 缺 name');
      expect(plugin.baseUrl.startsWith('http'), isTrue,
          reason: '${file.path} baseUrl 无效: ${plugin.baseUrl}');
      expect(plugin.searchURL.contains('@keyword') || plugin.api.isNotEmpty,
          isTrue,
          reason: '${file.path} 搜索入口缺少 @keyword 或 api 配置');
      names.add(plugin.name);
    }
    // 名称唯一（重名会互相覆盖安装目录里的文件）。
    expect(names.toSet().length, names.length,
        reason: '内置规则名称重复: $names');
  });

  test('LMM（v1.7.0 新增）在包内且带反爬配置', () {
    final lmm = File('assets/plugins/LMM.json');
    expect(lmm.existsSync(), isTrue);
    final plugin =
        Plugin.fromJson(jsonDecode(lmm.readAsStringSync()) as Map<String, dynamic>);
    expect(plugin.name, 'LMM');
    expect(plugin.baseUrl, 'https://www.lmm85.com/');
    // Cloudflare 质询站：无反爬配置的规则无法引导用户过验证。
    expect(plugin.antiCrawlerConfig.enabled, isTrue,
        reason: 'LMM 在 CF 质询后，必须带 antiCrawlerConfig 引导验证');
  });
}
