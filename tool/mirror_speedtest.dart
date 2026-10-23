// ignore_for_file: avoid_print
// 更新下载镜像实测：dart run tool/mirror_speedtest.dart [tag] [asset]
// 1) 对 ApiEndpoints 同款镜像列表并发测速；2) 用 MirrorDownloader 完整下载并校验 sha256。
import 'dart:convert';
import 'dart:io';

import 'package:miru/services/update/mirror_downloader.dart';

const prefixes = [
  'https://gh-proxy.com/',
  'https://hk.gh-proxy.com/',
  'https://cdn.gh-proxy.com/',
  'https://edgeone.gh-proxy.com/',
  'https://ghfast.top/',
  'https://gh-proxy.org/',
  'https://gh.llkk.cc/',
  'https://ghproxy.net/',
];

Future<void> main(List<String> args) async {
  final tag = args.isNotEmpty ? args[0] : 'v1.8.0';
  final asset = args.length > 1 ? args[1] : 'Miru_android_1.8.0.apk';
  final url =
      'https://github.com/DisenthrallClaude/Miru/releases/download/$tag/$asset';
  final client = HttpClient();
  final rel = await (await (await client.getUrl(Uri.parse(
              'https://api.github.com/repos/DisenthrallClaude/Miru/releases/tags/$tag')))
          .close())
      .transform(utf8.decoder)
      .join();
  final a = (jsonDecode(rel)['assets'] as List)
      .firstWhere((e) => e['name'] == asset);
  final digest = (a['digest'] as String? ?? '').replaceFirst('sha256:', '');
  final size = a['size'] as int;
  print('asset $asset size=$size sha256=$digest');
  final t = IoRangeTransport();
  final d = MirrorDownloader(transport: t);
  final probe = await d.probe(MirrorDownloader.buildCandidates(url, prefixes),
      expectedSize: size);
  print('== probe (512KB / 4s) ==');
  for (final p in probe) {
    print('  $p  latency=${p.latencyMs}ms range=${p.supportsRange}');
  }
  final dest = '${Directory.systemTemp.path}/miru_speedtest_$asset';
  final sw = Stopwatch()..start();
  var lastPrint = 0;
  final out = await d.download(
    url: url,
    mirrorPrefixes: prefixes,
    destPath: dest,
    expectedSha256: digest,
    expectedSize: size,
    onProgress: (p) {
      if (sw.elapsedMilliseconds - lastPrint > 2000) {
        lastPrint = sw.elapsedMilliseconds;
        print('  ${p.phase.name} ${(p.received / 1048576).toStringAsFixed(1)}MB '
            '${(p.bytesPerSecond / 1048576).toStringAsFixed(2)}MB/s ${p.sources}');
      }
    },
  );
  final secs = sw.elapsedMilliseconds / 1000;
  print('== full download: ${(size / 1048576).toStringAsFixed(1)}MB in '
      '${secs.toStringAsFixed(1)}s = ${(size / 1048576 / secs).toStringAsFixed(2)}MB/s, sha256 OK ==');
  await File(out.path).delete();
  t.close();
  client.close();
}
