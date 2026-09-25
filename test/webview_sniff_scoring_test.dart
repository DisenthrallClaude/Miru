// v1.7.0（P0-7/P1-2/P1-13）：WebView 嗅探层回归锁。
//
// - P0-7：Origin 不得覆盖 Referer（遍历顺序无关）；无 Referer 时
//   Origin+'/' 兜底；Origin 以独立键透传。
// - P1-13：候选打分——m3u8 > mp4；广告路径扣分；同域加分。
// - P1-2：PerformanceObserver 脚本在场（JS 侧过滤 + callHandler）。
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/webview/video/impl/video_webview_android_impl.dart';

void main() {
  group('P0-7：collectPlaybackHeaders（Referer/Origin 分离）', () {
    test('Referer 在前、Origin 在后：Origin 不得覆盖真实 Referer', () {
      final headers = VideoWebviewAndroidImplProbe.collectPlaybackHeaders(
        requestHeaders: {
          'Referer': 'https://cdn.example.com/play/123.html',
          'Origin': 'https://cdn.example.com',
        },
      );
      expect(headers['referer'], 'https://cdn.example.com/play/123.html',
          reason: '旧实现按遍历顺序把带路径的 Referer 覆盖成只有 '
              'scheme+host 的 Origin——严格校验 Referer 的 CDN 直接拒绝');
      expect(headers['origin'], 'https://cdn.example.com');
    });

    test('Origin 在前、Referer 在后（遍历顺序反转）：结果一致', () {
      final headers = VideoWebviewAndroidImplProbe.collectPlaybackHeaders(
        requestHeaders: {
          'Origin': 'https://cdn.example.com',
          'Referer': 'https://cdn.example.com/play/123.html',
        },
      );
      expect(headers['referer'], 'https://cdn.example.com/play/123.html');
      expect(headers['origin'], 'https://cdn.example.com');
    });

    test('只有 Origin：补 / 作 Referer 兜底', () {
      final headers = VideoWebviewAndroidImplProbe.collectPlaybackHeaders(
        requestHeaders: {'Origin': 'https://cdn.example.com'},
      );
      expect(headers['referer'], 'https://cdn.example.com/');
      expect(headers['origin'], 'https://cdn.example.com');
    });

    test('非拦截模式：JS 上报的文档 URL 作 Referer', () {
      final headers = VideoWebviewAndroidImplProbe.collectPlaybackHeaders(
        requestHeaders: null,
        documentUrl: 'https://www.example.com/player/1.html',
      );
      expect(headers['referer'], 'https://www.example.com/player/1.html');
    });

    test('Cookie 捕获（拦截模式）', () {
      final headers = VideoWebviewAndroidImplProbe.collectPlaybackHeaders(
        requestHeaders: {
          'Referer': 'https://cdn.example.com/',
          'Cookie': 'cf_clearance=x; a=1',
        },
      );
      expect(headers['cookie'], 'cf_clearance=x; a=1');
    });

    test('键名大小写不敏感 + 空值忽略', () {
      final headers = VideoWebviewAndroidImplProbe.collectPlaybackHeaders(
        requestHeaders: {
          'REFERER': 'https://r/',
          'origin': '',
          'COOKIE': 'a=1',
        },
      );
      expect(headers['referer'], 'https://r/');
      expect(headers.containsKey('origin'), isFalse);
      expect(headers['cookie'], 'a=1');
    });
  });

  group('P1-13：嗅探候选打分与选优', () {
    const pageUrl = 'https://www.anime-site.com/play/1.html';

    test('广告 m3u8 先到：正片靠打分胜出', () {
      final picked = VideoWebviewAndroidImplProbe.pickBestSniffCandidate([
        'https://ad-cdn.net/preroll/ad0.m3u8',
        'https://cdn.anime-site.com/video/ep01/index.m3u8',
      ], pageUrl: pageUrl);
      expect(picked, 'https://cdn.anime-site.com/video/ep01/index.m3u8',
          reason: '广告路径 -5 + 第三方域 0 分 vs 正片 m3u8+同域');
    });

    test('广告 mp4 vs 正片 m3u8：m3u8 胜出', () {
      final picked = VideoWebviewAndroidImplProbe.pickBestSniffCandidate([
        'https://ad-cdn.net/ads/promo.mp4',
        'https://cdn.anime-site.com/video/ep01.m3u8',
      ], pageUrl: pageUrl);
      expect(picked, 'https://cdn.anime-site.com/video/ep01.m3u8');
    });

    test('m3u8 > mp4（同域同优先级）', () {
      expect(
        VideoWebviewAndroidImplProbe.sniffCandidateScore(
            'https://cdn.anime-site.com/a.m3u8', pageUrl),
        greaterThan(VideoWebviewAndroidImplProbe.sniffCandidateScore(
            'https://cdn.anime-site.com/a.mp4', pageUrl)),
      );
    });

    test('广告路径特征命中扣分', () {
      final score = VideoWebviewAndroidImplProbe.sniffCandidateScore(
          'https://cdn.anime-site.com/preroll/ad.m3u8', pageUrl);
      expect(score, lessThan(0), reason: 'm3u8+3 + 同域+1 - 广告5 = -1');
    });

    test('并列取先到者', () {
      final picked = VideoWebviewAndroidImplProbe.pickBestSniffCandidate([
        'https://cdn.anime-site.com/first.m3u8',
        'https://cdn.anime-site.com/second.m3u8',
      ], pageUrl: pageUrl);
      expect(picked, 'https://cdn.anime-site.com/first.m3u8');
    });
  });

  group('P1-2：PerformanceObserver 嗅探脚本（源契约）', () {
    test('脚本在场且包含关键要素', () {
      final script = VideoWebviewAndroidImplProbe.perfObserverSniffScript();
      // JS 侧先按媒体扩展过滤（减少平台通道流量）。
      expect(script.contains('.m3u8'), isTrue);
      expect(script.contains('.mp4'), isTrue);
      // PerformanceObserver + buffered 历史。
      expect(script.contains('PerformanceObserver'), isTrue);
      expect(script.contains('buffered: true'), isTrue);
      // 上报带上文档 URL（Referer 来源）。
      expect(script.contains('window.location.href'), isTrue);
      // 防重复安装。
      expect(script.contains('__miruPerfObsInstalled'), isTrue);
      // 本地代理不嗅探。
      expect(script.contains('127.0.0.1'), isTrue);
    });
  });
}
