import 'package:flutter_test/flutter_test.dart';
import 'package:miru/utils/hls_ad_stripper.dart';

const _base = 'https://play.modujx10.com/20230907/Mbq8hdmq/1500kb/hls/index.m3u8';

String _main(String name, [double d = 3.6]) =>
    '#EXTINF:$d,\n/20230907/Mbq8hdmq/1500kb/hls/$name.ts';
String _ad(String name) =>
    '#EXTINF:1.955,\n/20261009/l7aBZIKL/10152kb/hls/$name.ts';

String _adGroup() => [
      '#EXT-X-DISCONTINUITY',
      for (var i = 0; i < 9; i++) _ad('ad$i'),
      '#EXT-X-DISCONTINUITY',
    ].join('\n');

List<String> _segs(String m3u8) => m3u8
    .split('\n')
    .where((l) => l.isNotEmpty && !l.startsWith('#'))
    .toList();

void main() {
  const head = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n'
      '#EXT-X-MEDIA-SEQUENCE:0';

  test('fcdm 实测形态：中插广告组（另一目录）全部剔除，正片一片不少', () {
    final m = [
      head,
      for (var i = 0; i < 47; i++) _main('a$i'),
      _adGroup(),
      for (var i = 0; i < 48; i++) _main('b$i'),
      _adGroup(),
      for (var i = 0; i < 144; i++) _main('c$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    final r = HlsAdStripper.strip(m, _base);
    expect(r.changed, isTrue);
    expect(r.removedGroups, 2);
    expect(r.leadingRemoved, isFalse);
    final segs = _segs(r.manifest);
    expect(segs.length, 47 + 48 + 144);
    expect(segs.any((s) => s.contains('20261009')), isFalse);
    expect(r.manifest.trimRight().endsWith('#EXT-X-ENDLIST'), isTrue);
    expect(r.manifest, contains('#EXT-X-TARGETDURATION:4'));
  });

  test('片头广告（第一组就是广告）：剔除且输出不以 DISCONTINUITY 开头', () {
    final m = [
      head,
      for (var i = 0; i < 9; i++) _ad('ad$i'),
      '#EXT-X-DISCONTINUITY',
      for (var i = 0; i < 300; i++) _main('m$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    final r = HlsAdStripper.strip(m, _base);
    expect(r.leadingRemoved, isTrue);
    final body = r.manifest.split('\n').where((l) => l.isNotEmpty).toList();
    final firstNonHeader =
        body.firstWhere((l) => l.startsWith('#EXTINF') || l.startsWith('#EXT-X-DISC'));
    expect(firstNonHeader.startsWith('#EXTINF'), isTrue);
    expect(_segs(r.manifest).first, contains('/m0.ts'));
  });

  test('无 DISCONTINUITY / 单目录：原样返回', () {
    final m = [head, for (var i = 0; i < 20; i++) _main('m$i'), '#EXT-X-ENDLIST']
        .join('\n');
    expect(HlsAdStripper.strip(m, _base).changed, isFalse);
    final m2 = [
      head,
      for (var i = 0; i < 20; i++) _main('m$i'),
      '#EXT-X-DISCONTINUITY',
      for (var i = 20; i < 40; i++) _main('m$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    expect(HlsAdStripper.strip(m2, _base).changed, isFalse);
  });

  test('超过 60s 的异目录段（片头曲/拼接正片）不动', () {
    final m = [
      head,
      for (var i = 0; i < 30; i++)
        '#EXTINF:3.0,\n/20220101/OPxxxx/1500kb/hls/op$i.ts',
      '#EXT-X-DISCONTINUITY',
      for (var i = 0; i < 300; i++) _main('m$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    expect(HlsAdStripper.strip(m, _base).changed, isFalse);
  });

  test('安全阀：异目录短段总量超过 25% 不动', () {
    final m = [
      head,
      for (var g = 0; g < 6; g++) ...[
        for (var i = 0; i < 5; i++) _main('m$g$i'),
        '#EXT-X-DISCONTINUITY',
        for (var i = 0; i < 5; i++)
          '#EXTINF:3.6,\n/other$g/hls/x$i.ts',
        '#EXT-X-DISCONTINUITY',
      ],
      '#EXT-X-ENDLIST',
    ].join('\n');
    expect(HlsAdStripper.strip(m, _base).changed, isFalse);
  });

  test('广告段改了 KEY：删除后按原清单语义补回 KEY 状态（不串用正片密钥）', () {
    const mainKey =
        '#EXT-X-KEY:METHOD=AES-128,URI="enc.key",IV=0x00000000000000000000000000000000';
    final m = [
      head,
      mainKey,
      for (var i = 0; i < 100; i++) _main('a$i'),
      '#EXT-X-DISCONTINUITY',
      '#EXT-X-KEY:METHOD=NONE',
      for (var i = 0; i < 9; i++) _ad('ad$i'),
      '#EXT-X-DISCONTINUITY',
      mainKey,
      for (var i = 0; i < 100; i++) _main('b$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    final r = HlsAdStripper.strip(m, _base);
    expect(r.removedGroups, 1);
    expect(r.manifest, isNot(contains('METHOD=NONE')));
    final lines = r.manifest.split('\n');
    final b0 = lines.indexWhere((l) => l.endsWith('/b0.ts'));
    expect(lines.lastIndexWhere((l) => l == mainKey, b0),
        greaterThan(lines.lastIndexWhere((l) => l == '#EXT-X-DISCONTINUITY', b0)));
  });

  test('原清单中广告后的正片沿用广告的 KEY 状态时，补回该状态（规范语义）', () {
    final m = [
      head,
      '#EXT-X-KEY:METHOD=AES-128,URI="enc.key"',
      for (var i = 0; i < 100; i++) _main('a$i'),
      '#EXT-X-DISCONTINUITY',
      '#EXT-X-KEY:METHOD=NONE',
      for (var i = 0; i < 9; i++) _ad('ad$i'),
      '#EXT-X-DISCONTINUITY',
      for (var i = 0; i < 100; i++) _main('b$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    final lines = HlsAdStripper.strip(m, _base).manifest.split('\n');
    final b0 = lines.indexWhere((l) => l.endsWith('/b0.ts'));
    expect(lines.lastIndexWhere((l) => l == '#EXT-X-KEY:METHOD=NONE', b0),
        greaterThan(lines.lastIndexWhere((l) => l == '#EXT-X-DISCONTINUITY', b0)));
  });

  test('片头广告带 METHOD=NONE、正片加密：正片 KEY 保持在首片之前', () {
    const mainKey = '#EXT-X-KEY:METHOD=AES-128,URI="k.key"';
    final m = [
      head,
      for (var i = 0; i < 6; i++) _ad('ad$i'),
      '#EXT-X-DISCONTINUITY',
      mainKey,
      for (var i = 0; i < 200; i++) _main('m$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    final r = HlsAdStripper.strip(m, _base);
    final lines = r.manifest.split('\n');
    expect(lines.indexOf(mainKey),
        lessThan(lines.indexWhere((l) => l.endsWith('/m0.ts'))));
  });

  test('广告 URL 规则命中（同目录 adposter）也剔除', () {
    final m = [
      head,
      '#EXTINF:5,\n/20230907/Mbq8hdmq/1500kb/hls/adposter.ts',
      '#EXT-X-DISCONTINUITY',
      for (var i = 0; i < 100; i++) _main('m$i'),
      '#EXT-X-ENDLIST',
    ].join('\n');
    expect(HlsAdStripper.strip(m, _base).removedGroups, 1);
  });

  test('主清单原样返回', () {
    const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n1500kb/index.m3u8\n'
        '#EXT-X-DISCONTINUITY';
    expect(HlsAdStripper.strip(master, _base).changed, isFalse);
  });
}
