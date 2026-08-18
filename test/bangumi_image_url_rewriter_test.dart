import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/bangumi_image_url_rewriter.dart';

void main() {
  group('BangumiImageUrlRewriter', () {
    test('keeps URLs unchanged when disabled', () {
      const url = 'https://api.bgm.tv/v0/subjects/590353/image?type=large';

      expect(BangumiImageUrlRewriter.rewrite(url, enabled: false), url);
    });

    test('rewrites official lain images onto the community image proxy', () {
      expect(
        BangumiImageUrlRewriter.rewrite(
          'https://lain.bgm.tv/pic/cover/l/cover.jpg',
          enabled: true,
        ),
        'https://bgmimg.anibt.net/pic/cover/l/cover.jpg',
      );
      expect(
        BangumiImageUrlRewriter.rewrite(
          'https://lain.bgm.tv/pic/cover/l/animated.gif',
          enabled: true,
        ),
        'https://bgmimg.anibt.net/pic/cover/l/animated.gif',
      );
    });

    test('rewrites synthetic API image endpoints', () {
      for (final type in ['subjects', 'characters', 'persons']) {
        final source = 'https://api.bgm.tv/v0/$type/590353/image?type=large';
        expect(
          BangumiImageUrlRewriter.rewrite(source, enabled: true),
          'https://wsrv.nl/?url=api.bgm.tv%2Fv0%2F$type%2F590353%2Fimage%3Ftype%3Dlarge',
        );
      }
    });

    test('把 next 反代图床归一到搜索反代图床（置顶番剧封面丢失的修复）', () {
      expect(
        BangumiImageUrlRewriter.rewrite(
          'https://lain.bangumi.lol/pic/cover/l/4d/e3/153197_m55EA.jpg',
          enabled: true,
        ),
        'https://bgmimg.anibt.net/pic/cover/l/4d/e3/153197_m55EA.jpg',
      );
      // 关闭代理时保持原样
      expect(
        BangumiImageUrlRewriter.rewrite(
          'https://lain.bangumi.lol/pic/cover/l/cover.jpg',
          enabled: false,
        ),
        'https://lain.bangumi.lol/pic/cover/l/cover.jpg',
      );
    });

    test('rejects URLs outside the image boundary', () {
      for (final url in [
        'ftp://lain.bgm.tv/pic/cover/l/cover.jpg',
        'https://api.bgm.tv/v0/subjects/590353',
        'https://api.bgm.tv/v0/subjects/not-an-id/image?type=large',
        'https://api.bgm.tv/v0/episodes/1/image?type=large',
        'https://example.com/v0/subjects/590353/image?type=large',
      ]) {
        expect(BangumiImageUrlRewriter.rewrite(url, enabled: true), url);
      }
    });
  });
}
