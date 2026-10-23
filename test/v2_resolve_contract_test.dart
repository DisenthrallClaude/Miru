import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v2: 用户显式重试接通 force（忽略负缓存/短窗失败记忆）', () {
    final ctrl = File('lib/pages/video/video_controller.dart').readAsStringSync();
    expect(ctrl.contains('force: forceResolve'), isTrue);
    final page = File('lib/pages/video/video_page.dart').readAsStringSync();
    expect('forceResolve: true'.allMatches(page).length, greaterThanOrEqualTo(2),
        reason: '错误页「重试」与顶栏刷新都必须强制重解析');
  });

  test('v2: 云端结果也过广告过滤（正式解析与预取）', () {
    final s = File('lib/services/video_source/hybrid_video_source_service.dart')
        .readAsStringSync();
    expect('AdUrlFilter.isAd(cloudResult.url)'.allMatches(s).length, 2);
  });
}
