// v1.8.0：rules_research 入选的 4 条国漫规则内置 + 优先级排序。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/plugins/bundled_rule_priority.dart';
import 'package:miru/plugins/plugins.dart';
import 'package:miru/plugins/rule_policy.dart';

Plugin load(String name) => Plugin.fromJson(
    jsonDecode(File('assets/plugins/$name.json').readAsStringSync())
        as Map<String, dynamic>);

void main() {
  const added = ['jciyuan', 'dmjd', 'dmttang', 'milimili'];

  test('四条新规则在包内、可解析、不在日漫/失效名单', () {
    for (final n in added) {
      final p = load(n);
      expect(p.name, n);
      expect(kJapaneseRuleNames.map((e) => e.toLowerCase()), isNot(contains(n)));
      expect(kBrokenRuleNames.map((e) => e.toLowerCase()), isNot(contains(n)));
    }
  });

  test('待大陆实测的 cycani / yhdm6 / anime7 不内置', () {
    for (final n in ['cycani', 'yhdm6', 'anime7']) {
      expect(File('assets/plugins/$n.json').existsSync(), isFalse);
    }
  });

  test('新装：jciyuan、dmjd 在最前，dmttang、milimili 在最后', () {
    final files = Directory('assets/plugins')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final bundled = [
      for (final f in files)
        Plugin.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
    ];
    BundledRulePriority.sort(bundled);
    final names = bundled.map((p) => p.name).toList();
    expect(names.take(2), ['jciyuan', 'dmjd']);
    expect(names.skip(names.length - 2), ['dmttang', 'milimili']);
  });

  test('老用户：新高优先级规则插到前面，原有顺序不变；低优先级追加末尾', () {
    final list = [load('fcdm'), load('7sefun'), load('MXdm')];
    BundledRulePriority.insertNew(list, load('dmjd'));
    BundledRulePriority.insertNew(list, load('jciyuan'));
    BundledRulePriority.insertNew(list, load('milimili'));
    expect(list.map((p) => p.name),
        ['jciyuan', 'dmjd', 'fcdm', '7sefun', 'MXdm', 'milimili']);
  });
}
