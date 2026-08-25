import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';

void main() {
  test('p1 (next 反代) 响应能正确解析出封面', () {
    final raw = File('test/fixtures/p1_subject_153197.json').readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final item = BangumiItem.fromJson(json);
    expect(item.nameCn, '斗破苍穹');
    expect(item.images['large'], isNotNull);
    expect(item.images['large'], isNotEmpty);
  });
}
