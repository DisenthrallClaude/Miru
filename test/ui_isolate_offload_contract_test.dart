// v1.7.0（P1-7/P1-8）：UI isolate 减负契约锁。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;

  String source(String rel) =>
      File.fromUri(root.uri.resolve(rel)).readAsStringSync();

  group('P1-7：重提取移出 UI isolate', () {
    test('快解层：大页面（≥32KB）候选提取走 Isolate.run', () {
      final s = source('lib/services/video_source/fast_video_source_resolver.dart');
      expect(s.contains('_isolateExtractionThreshold = 32 * 1024'), isTrue);
      expect(s.contains('Isolate.run('), isTrue,
          reason: '大页面纯提取必须移出 UI isolate（多组正则+括号配平在 '
              '1MB HTML 上几十毫秒级，加载期间掉帧并拖慢 WebView 回调）');
      expect(s.contains('parseStaticCandidatesFromHtml'), isTrue,
          reason: '纯提取拆为顶层静态函数（isolate 安全，无实例状态）');
      // 低于阈值同步执行（spawn 开销 > 提取耗时）。
      expect(s.contains('html.length >= _isolateExtractionThreshold'), isTrue);
    });

    test('xpath 规则引擎：大页面 parse+求值走 Isolate.run', () {
      final s = source('lib/services/plugin/xpath_rule_strategy.dart');
      expect(s.contains('isolateThreshold = 32 * 1024'), isTrue);
      expect(s.contains('parseSearchAsync'), isTrue);
      expect(s.contains('parseChaptersAsync'), isTrue);
      final re = source('lib/services/plugin/rule_engine.dart');
      expect(re.contains('parseSearchAsync'), isTrue,
          reason: '搜索路径必须用 isolate 感知入口');
      expect(re.contains('parseChaptersAsync'), isTrue,
          reason: '章节路径必须用 isolate 感知入口');
    });
  });

  group('P1-8：播放页不因日志整页重建', () {
    test('webviewLogLines 是 ValueNotifier，无日志 setState', () {
      final s = source('lib/pages/video/video_page.dart');
      expect(s.contains('ValueNotifier<List<String>> webviewLogLines'), isTrue);
      expect(s.contains('ValueListenableBuilder<List<String>>'), isTrue,
          reason: '调试控制台用订阅重建，日志更新不触发整页 setState');
      // 日志监听里不再有 setState 调用（匹配调用语法，注释不算）。
      final listenerStart = s.indexOf('logStream.listen');
      final listenerEnd = s.indexOf('});', listenerStart);
      final listenerBody = s.substring(listenerStart, listenerEnd);
      expect(listenerBody.contains('setState(()'), isFalse,
          reason: '每行日志一次整页 setState（含播放器子树重建几十次/秒）'
              '必须移除');
    });
  });
}
