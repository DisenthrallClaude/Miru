// v1.7.0（P2-1~4/9~18）：正确性与健壮性条目契约锁。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';

void main() {
  final root = Directory.current;

  String source(String rel) =>
      File.fromUri(root.uri.resolve(rel)).readAsStringSync();

  group('P2-1：解析器名单精确匹配 + 直链双候选', () {
    test('分词匹配：player 不再被 play 误伤（名单不含 play）', () {
      // 'play' 不在名单里（本就不该在）；'parse' 在名单里但分词后才匹配。
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'player', 'https://x.com/v.m3u8'),
          isFalse,
          reason: 'from=player 是正常播放器，不该走二跳');
    });

    test('分词匹配：qqjx 命中 jx', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'qqjx', 'token-abc'),
          isTrue,
          reason: '按 [\\W_] 分词后 qqjx → [qqjx]，qq/jx 任一在名单即命中');
    });

    test('完整名命中：名单内 from 名直接匹配', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isThirdPartyParser(
              'jsonjx', 'token-abc'),
          isTrue);
    });

    test('源契约：直链形态的 url 同时进 direct 候选', () {
      final s = source('lib/services/video_source/fast_video_source_resolver.dart');
      expect(
          s.contains('url 本身就是直链形态时同时加入 direct 候选'),
          isTrue,
          reason: 'P2-1：解析器挂了时明明可播的直链不再丢');
    });
  });

  group('P2-2/P2-3：URL 判定与补全', () {
    test('player 主机名 + 普通路径不再判为媒体', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://player.xxx.com/share/abc'),
          isFalse,
          reason: "P2-2：'play' 移出 host 弱信号");
    });

    test('/hls/ 路径仍判为媒体', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://player.xxx.com/hls/abc'),
          isTrue);
    });

    test('cdn 主机 + 深路径仍判为媒体', () {
      expect(
          FastVideoSourceResolverCandidateProbe.isLikelyMediaUrl(
              'https://cdn.xxx.com/a/b/video'),
          isTrue);
    });
  });

  group('P2-9：代理回源接受 2xx', () {
    test('源契约：清单回源不再只认 200', () {
      final s = source('lib/services/video_source/local_media_proxy.dart');
      expect(s.contains('response.statusCode < 200 || response.statusCode >= 300'),
          isTrue,
          reason: '部分 CDN 返回 203/206，旧实现永远拉不到清单');
    });
  });

  group('P2-10：友好错误文案', () {
    test('超时族 → 可操作文案', () {
      final s = source('lib/pages/video/video_controller.dart');
      expect(s.contains('String friendlyResolveError(Object e)'), isTrue);
      expect(s.contains('_failLoading(friendlyResolveError(e))'), isTrue);
      expect(s.contains("_failLoading('视频解析失败：\${e.toString()}')"), isFalse,
          reason: '原始异常 toString 不再怼给用户');
    });
  });

  group('P2-12/P2-16/P2-17：action/熔断/加载完成', () {
    test('全屏写入统一 @action', () {
      final s = source('lib/pages/video/video_controller.dart');
      expect(s.contains('@action\n  void enterFullScreen()'), isTrue);
      expect(s.contains('@action\n  void handleOnEnterFullScreen()'), isTrue);
    });

    test('熔断名额只在真正切换后消耗', () {
      final s = source('lib/pages/video/video_controller.dart');
      expect(s.contains('熔断名额只在'), isTrue);
      // _autoFallbackCount++ 移到 _applyFallbackContext 前。
      final idx = s.indexOf('_autoFallbackCount++;');
      final applyIdx = s.indexOf('_applyFallbackContext(candidate, roads);');
      expect(idx, greaterThan(0));
      expect(applyIdx, greaterThan(idx),
          reason: '计数在真正切换（applyFallbackContext）时递增');
    });

    test('页面加载完成改用结构化事件（不再匹配日志文案）', () {
      final base =
          source('lib/webview/video/video_webview_controller.dart');
      expect(base.contains('Stream<String> get onPageFinished'), isTrue);
      final svc = source(
          'lib/services/video_source/webview_video_source_service.dart');
      expect(svc.contains('webview.onPageFinished.listen'), isTrue);
      expect(svc.contains("log.startsWith('loading completed')"), isFalse,
          reason: 'P2-17：日志文案匹配已废弃');
    });
  });

  group('P2-15：明文流量默认禁止', () {
    test('manifest 走 network_security_config（本地代理放行）', () {
      final manifest = source('android/app/src/main/AndroidManifest.xml');
      expect(manifest.contains('usesCleartextTraffic="true"'), isFalse);
      expect(
          manifest.contains(
              'android:networkSecurityConfig="@xml/network_security_config"'),
          isTrue);
      final nsc = source(
          'android/app/src/main/res/xml/network_security_config.xml');
      expect(nsc.contains('cleartextTrafficPermitted="false"'), isTrue);
      expect(nsc.contains('127.0.0.1'), isTrue,
          reason: '本地媒体代理必须放行 http 回环');
    });
  });

  group('P2-14：Worker 安全加固（源契约）', () {
    test('host 白名单 + 签名感知 TTL + CORS 收紧', () {
      final w = source('cloudflare-worker/miru-resolver/src/worker.js');
      expect(w.contains('DEFAULT_ALLOWED_HOSTS'), isTrue);
      expect(w.contains('isHostAllowed'), isTrue);
      expect(w.contains('host-not-allowed'), isTrue);
      expect(w.contains('signatureAwareTtlSeconds'), isTrue);
      expect(w.contains("env.ALLOWED_ORIGINS || '*'"), isFalse,
          reason: 'CORS 不再默认 *');
      final toml = source('cloudflare-worker/miru-resolver/wrangler.toml');
      expect(toml.contains('ALLOWED_HOSTS'), isTrue);
      expect(toml.contains('cfut_'), isFalse, reason: 'Token 绝不落盘');
    });
  });

  group('P2-13：关键链路静默 catch 清理', () {
    test('空 catch(_) {} 在播放/解析/代理链路已消灭', () {
      for (final p in [
        'lib/pages/player/controller/player_playback_controller.dart',
        'lib/services/video_source/hybrid_video_source_service.dart',
        'lib/services/video_source/local_media_proxy.dart',
        'lib/services/video_source/fast_video_source_resolver.dart',
      ]) {
        final s = source(p);
        expect(RegExp(r'catch \(_\) \{\s*\}').hasMatch(s), isFalse,
            reason: '$p 仍存在零观测的空 catch');
      }
    });
  });
}
