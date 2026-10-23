import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';

void main() {
  test('v2: player_aaaa.url 指向 HTML 播放页 → 走 iframe 二跳，不当直链', () {
    const html = '<script>var player_aaaa={"url":"https://www.lmm85.com/play/123-1-1.html","from":"lmm","encrypt":0}</script>';
    final p = FastVideoSourceResolver.parseStaticCandidatesFromHtml(
        html, 'https://www.7sefun.top/play/1.html', 'https://www.7sefun.top/');
    expect(p.direct.where((c) => c.url.endsWith('.html')), isEmpty);
    expect(p.iframeUrl, 'https://www.lmm85.com/play/123-1-1.html');
  });

  test('v2: 内联直链里的 \\uXXXX 转义被还原并编码', () {
    const html = r'<script>var u="https:\/\/cdn.x.com\/\u51e1\u4eba\/index.m3u8";</script>';
    final p = FastVideoSourceResolver.parseStaticCandidatesFromHtml(
        html, 'https://dmghg.com/p/1', 'https://dmghg.com/');
    final inline = p.direct.single.url;
    expect(inline.contains(r'\u'), isFalse);
    expect(Uri.decodeFull(inline), 'https://cdn.x.com/凡人/index.m3u8');
  });

  test('v2: 广告片不进候选', () {
    const html = '<script>var u="https://vip.x.com/Play/adposter.mp4";</script>';
    final p = FastVideoSourceResolver.parseStaticCandidatesFromHtml(
        html, 'https://age.tv/p/1', 'https://age.tv/');
    expect(p.direct, isEmpty);
  });
}
