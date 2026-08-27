import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';
import 'package:miru/services/video_source/video_source_format.dart';
import 'package:miru/services/video_source/video_source_service.dart';

/// 本地媒体代理（秒开链路）的纯逻辑单测：
/// - 相对地址补全 absolutizeUrl
/// - HLS 清单改写 rewriteManifest（分片指向代理 / KEY URI 绝对化）
/// - 分片地址提取 extractSegmentUrls
/// - VideoSource 的 directUrl 语义
void main() {
  group('absolutizeUrl', () {
    test('绝对地址原样返回', () {
      expect(absolutizeUrl('https://cdn.example.com/v/a.m3u8', 'https://x.com/p/1'),
          'https://cdn.example.com/v/a.m3u8');
    });

    test('协议相对地址补 https', () {
      expect(absolutizeUrl('//cdn.example.com/v/a.m3u8', 'https://x.com/p/1'),
          'https://cdn.example.com/v/a.m3u8');
    });

    test('相对路径基于清单地址解析', () {
      expect(
        absolutizeUrl('seg-001.ts', 'https://cdn.example.com/v/index.m3u8'),
        'https://cdn.example.com/v/seg-001.ts',
      );
      expect(
        absolutizeUrl('../hls/seg-001.ts', 'https://cdn.example.com/v/a/index.m3u8'),
        'https://cdn.example.com/v/hls/seg-001.ts',
      );
    });

    test('根相对路径', () {
      expect(
        absolutizeUrl('/static/v/seg.ts', 'https://cdn.example.com/v/index.m3u8'),
        'https://cdn.example.com/static/v/seg.ts',
      );
    });

    test('空地址返回 null', () {
      expect(absolutizeUrl('  ', 'https://x.com/a.m3u8'), isNull);
    });
  });

  group('rewriteManifest', () {
    const manifest = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="enc.key"
#EXTINF:5.76,
seg-001.ts
#EXTINF:5.76,
seg-002.ts
#EXT-X-ENDLIST
''';

    test('分片 URL 改写为代理地址，KEY URI 绝对化', () {
      final proxy = LocalMediaProxy.instance;
      final rewritten = proxy.rewriteManifest(
        manifest,
        'https://cdn.example.com/v/index.m3u8',
        (abs) => 'http://127.0.0.1:9/SECRET/seg/${abs.hashCode}?u=${Uri.encodeComponent(abs)}',
      );

      // KEY 绝对化
      expect(
        rewritten,
        contains('URI="https://cdn.example.com/v/enc.key"'),
      );
      // 分片改写
      expect(rewritten, isNot(contains('\nseg-001.ts')));
      expect(rewritten, contains('127.0.0.1:9/SECRET/seg/'));
      expect(rewritten, contains(Uri.encodeComponent('https://cdn.example.com/v/seg-001.ts')));
      expect(rewritten, contains(Uri.encodeComponent('https://cdn.example.com/v/seg-002.ts')));
      // 清单结构保持
      expect(rewritten.startsWith('#EXTM3U'), isTrue);
      expect(rewritten, contains('#EXT-X-ENDLIST'));
    });

    test('已是绝对地址的分片不经过 base 解析', () {
      final proxy = LocalMediaProxy.instance;
      const absManifest = '#EXTM3U\n#EXTINF:5.0,\nhttps://other.cdn/s/1.ts\n';
      final rewritten = proxy.rewriteManifest(
        absManifest,
        'https://cdn.example.com/v/index.m3u8',
        (abs) => 'PROXY($abs)',
      );
      expect(rewritten, contains('PROXY(https://other.cdn/s/1.ts)'));
    });
  });

  group('extractSegmentUrls', () {
    test('提取全部非注释行为绝对地址', () {
      final proxy = LocalMediaProxy.instance;
      const m = '#EXTM3U\n#EXTINF:1,\na.ts\n#EXT-X-DISCONTINUITY\nb.ts\n';
      final urls = proxy.extractSegmentUrls(m, 'https://c.com/p/index.m3u8');
      expect(urls, ['https://c.com/p/a.ts', 'https://c.com/p/b.ts']);
    });

    test('空行与纯注释清单返回空列表', () {
      final proxy = LocalMediaProxy.instance;
      expect(proxy.extractSegmentUrls('#EXTM3U\n', 'https://c.com/i.m3u8'), isEmpty);
    });
  });

  group('VideoSource.directUrl', () {
    test('未提供时与 url 相同（直连场景）', () {
      const source = VideoSource(
        url: 'https://cdn.example.com/v/a.m3u8',
        offset: 0,
        type: VideoSourceType.online,
      );
      expect(source.directUrl, source.url);
      expect(source.isProxied, isFalse);
    });

    test('代理场景 directUrl 保留原始直链', () {
      const source = VideoSource(
        url: 'http://127.0.0.1:12345/s3cr3t/m3u8/abc?u=x',
        offset: 12,
        type: VideoSourceType.online,
        format: VideoSourceFormat.hls,
        directUrl: 'https://cdn.example.com/v/a.m3u8',
      );
      expect(source.directUrl, 'https://cdn.example.com/v/a.m3u8');
      expect(source.isProxied, isTrue);
      expect(source.offset, 12);
      expect(source.format, VideoSourceFormat.hls);
    });
  });
}
