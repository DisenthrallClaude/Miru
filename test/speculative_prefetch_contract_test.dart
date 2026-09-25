// v1.7.0（P0-9/P1-5/P1-12）：投机解析/选集超时/预解析时机 契约锁。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;

  String source(String rel) =>
      File.fromUri(root.uri.resolve(rel)).readAsStringSync();

  group('P0-9：选集拉取超时与可取消', () {
    test('source_sheet：12s 超时 + 移动端 barrierDismissible', () {
      final s = source('lib/pages/info/source_sheet.dart');
      expect(s.contains('barrierDismissible: true'), isTrue,
          reason: 'P0-9：移动端也允许点遮罩取消——源站挂起时用户不再'
              '被困在「获取中」');
      expect(s.contains('const Duration(seconds: 12)'), isTrue,
          reason: 'P0-9：queryChapterRoads 自身无超时，必须有 12s 硬顶');
      expect(s.contains('cancelToken.cancel();'), isTrue,
          reason: '超时/取消必须传导到规则引擎令牌');
    });

    test('video_controller：兜底换源的选集拉取同样 12s 超时', () {
      final s = source('lib/pages/video/video_controller.dart');
      expect(
          s.contains(
              "queryChapterRoads(candidate.src)\n            .timeout(const Duration(seconds: 12))"),
          isTrue,
          reason: 'P0-9：兜底换源路径同样要有超时');
      expect(s.contains('on TimeoutException'), isTrue,
          reason: '超时算一次失败，继续尝试下一个候选（不占熔断名额语义）');
    });
  });

  group('P1-5：投机解析', () {
    test('source_sheet：点下即预解析目标集（历史集或第 1 集）', () {
      final s = source('lib/pages/info/source_sheet.dart');
      expect(s.contains('_speculativelyResolveTarget'), isTrue);
      expect(s.contains('PlaybackTimelineRecorder.instance.markTap'), isTrue,
          reason: '时间线 tTap 前移到真实点击时刻');
      expect(
          s.contains('HybridVideoSourceService.shared.prefetchResolve'), isTrue,
          reason: '投机解析走 shared 单例（与正式解析单飞共享）');
      expect(s.contains('lastWatching'), isTrue,
          reason: '目标集 = 历史进度集或第 1 集');
    });

    test('video_page：首播不 await bestRoadIndex（同步内存分）', () {
      final s = source('lib/pages/video/video_page.dart');
      expect(s.contains('cachedBestRoadIndex'), isTrue,
          reason: 'P1-5 条2：同步内存健康分，绝不阻塞首播');
      expect(s.contains('await RoadHealthTracker.instance.bestRoadIndex'),
          isFalse,
          reason: '首播路径不得 await 磁盘健康分读取');
      expect(s.contains('scheduleMicrotask'), isTrue,
          reason: 'P1-5 条3：changeEpisode 微任务即刻触发，不等 postFrame');
    });

    test('info_page：插件站点预连接（DNS+TLS 提前握手）', () {
      final s = source('lib/pages/info/info_page.dart');
      expect(s.contains('_preConnectPluginHosts'), isTrue);
      expect(s.contains("openUrl('HEAD', uri)"), isTrue);
      expect(s.contains('WebViewPool.instance.preheat'), isTrue,
          reason: 'P1-1 条2：进详情页预热 WebView 池');
    });
  });

  group('P1-12：下一集预解析时机', () {
    test('触发条件 = 首帧 + 缓冲余粮 ≥ 20s（MobX when）', () {
      final s = source('lib/pages/video/video_controller.dart');
      expect(s.contains('_nextEpisodePrefetchReaction = when('), isTrue,
          reason: '固定 8s 定时器 → when(hasVideoParams && buffer≥20s)');
      expect(s.contains('Duration(seconds: 20)'), isTrue);
      // 旧固定定时器已移除。
      expect(s.contains('Timer(const Duration(seconds: 8)'), isFalse,
          reason: '旧的固定 8s 触发必须移除');
    });

    test('dispose 补上 _prefetchSessions 取消（此前遗漏）', () {
      final s = source('lib/pages/video/video_controller.dart');
      final disposeBody = _extractMethod(s, 'void dispose()');
      expect(disposeBody, isNotNull);
      expect(disposeBody!.contains('_prefetchSessions.cancel()'), isTrue,
          reason: '退出播放页后仍在途的预取回调不得继续解析+下载');
      expect(disposeBody.contains('_nextEpisodePrefetchReaction'), isTrue);
    });

    test('剩余 < 3 分钟时预取下一集开头分片', () {
      final s = source('lib/pages/video/video_controller.dart');
      expect(s.contains('prefetchDataForNextEpisode'), isTrue);
      expect(s.contains('Duration(minutes: 3)'), isTrue);
    });
  });

  group('P1-11：线路健康探测让位首播', () {
    test('探测改在首帧后 5s，并发降为 2', () {
      final page = source('lib/pages/video/video_page.dart');
      expect(page.contains('_scheduleRoadHealthProbeAfterFirstFrame'), isTrue,
          reason: '探测不再进页立即执行');
      expect(page.contains('Duration(seconds: 5)'), isTrue);

      final rh = source('lib/services/video_source/road_health.dart');
      expect(rh.contains('static const int concurrency = 2;'), isTrue,
          reason: '4 → 2：不与首播抢连接配额');
      expect(rh.contains('_probingPlugins'), isTrue,
          reason: '全局布尔 → per-plugin 集合');
      expect(rh.contains('recordOutcome'), isTrue,
          reason: '真实播放结果回填通道');
    });
  });
}

String? _extractMethod(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return null;
  final bodyStart = source.indexOf('{', start);
  if (bodyStart < 0) return null;
  var depth = 0;
  for (var i = bodyStart; i < source.length; i++) {
    final ch = source[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(bodyStart, i + 1);
      }
    }
  }
  return null;
}
