import 'package:flutter_test/flutter_test.dart';
import 'package:miru/utils/ad_url_filter.dart';

void main() {
  group('AdUrlFilter', () {
    test('AGE 解析器广告片判为广告', () {
      expect(
          AdUrlFilter.isAd('https://vip.sp-flv.com:8443/Play/adposter.mp4'),
          isTrue);
      expect(AdUrlFilter.isAd('https://x.com/ads/pre.m3u8'), isTrue);
      expect(AdUrlFilter.isAd('https://x.com/v/pre_ad.mp4'), isTrue);
      expect(AdUrlFilter.isAd('https://pagead2.googlesyndication.com/x.js'),
          isTrue);
    });

    test('正片不误伤', () {
      for (final u in [
        'https://play.xluuss.com/20240101/abc/index.m3u8',
        'https://v.cdnlz.com/20231111/12345_aa/index.m3u8',
        'https://ok.ffzy.com/share/download.mp4',
        'https://x.com/video/road.mp4',
        'https://x.com/upload/index.m3u8?ad=1',
        'https://x.com/headline/1080/index.m3u8',
      ]) {
        expect(AdUrlFilter.isAd(u), isFalse, reason: u);
      }
    });
  });
}
