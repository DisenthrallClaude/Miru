import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/request/config/hero_banners.dart';

void main() {
  test('所有轮播条目的 p1 响应都能解析（否则点击会报「加载失败」）', () {
    for (final banner in kHeroBanners) {
      final f = File('test/fixtures/${banner.subjectId}.json');
      expect(f.existsSync(), isTrue,
          reason: '缺少 ${banner.title} (${banner.subjectId}) 的样本');
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      late BangumiItem item;
      expect(() => item = BangumiItem.fromJson(json), returnsNormally,
          reason: '${banner.title} 解析抛异常');
      expect(item.id, banner.subjectId);
      expect(item.images['large'], isNotEmpty,
          reason: '${banner.title} 没有封面');
    }
  });
}
