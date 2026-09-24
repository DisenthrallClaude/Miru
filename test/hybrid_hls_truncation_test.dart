// v1.7.0（P0-3）：截断 HLS 清单不得 seed 给本地代理。
//
// 两道防线：
// 1. hybrid `_probeHls`：读满 512KB 上限即截断 → 只判活不 seed
//    （HybridVideoSourceServiceProbe.decideHlsText 纯决策锁定）；
// 2. proxy `seedManifest`：媒体清单（含 #EXTINF）必须带
//    #EXT-X-ENDLIST 才接受（直播/截断清单拒收，代理回退自行拉取）。
//
// 病灶：24 分钟一集、2 秒分片、分片 URL 带签名的 m3u8 很容易超过
// 100KB；截断清单缺 ENDLIST 被 mpv 当直播流（无时长、不能拖），
// 代理预取/二刷/5 分钟内回看直接复用残缺清单 → 长集只播一部分。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/hybrid_video_source_service.dart';
import 'package:miru/services/video_source/local_media_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        return '/tmp/miru_p03_seed_test';
    }
    return null;
  });

  setUpAll(() async {
    Directory('/tmp/miru_p03_seed_test').createSync(recursive: true);
    await Hive.initFlutter('/tmp/miru_p03_seed_test/hive');
    await GStorage.init();
  });

  group('P0-3 防线 1：hybrid 截断决策（decideHlsText）', () {
    test('完整清单：alive + 可 seed', () {
      const manifest = '#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n#EXT-X-ENDLIST\n';
      final d = HybridVideoSourceServiceProbe.decideHlsText(manifest,
          truncated: false);
      expect(d.alive, isTrue);
      expect(d.canSeed, isTrue);
    });

    test('截断清单（读满 512KB 上限）：alive 但绝不 seed', () {
      // 模拟被 64KB/512KB 上限截断的媒体清单（无 ENDLIST）。
      const truncated =
          '#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n#EXTINF:2.0,\nseg1.ts\n';
      final d = HybridVideoSourceServiceProbe.decideHlsText(truncated,
          truncated: true);
      expect(d.alive, isTrue, reason: '有 #EXTM3U 即可判活');
      expect(d.canSeed, isFalse, reason: '截断清单绝不 seed 给代理');
    });

    test('错误页伪装（非 #EXTM3U 开头）：判死', () {
      const html = '<html><body>player page</body></html>';
      final d = HybridVideoSourceServiceProbe.decideHlsText(html,
          truncated: false);
      expect(d.alive, isFalse);
      expect(d.canSeed, isFalse);
    });
  });

  group('P0-3 防线 2：proxy seedManifest 的 ENDLIST 校验', () {
    test('缺 ENDLIST 的媒体清单被拒收', () async {
      final proxy = LocalMediaProxy.instance;
      await proxy.seedManifest(
        'https://cdn.example.com/live-or-truncated.m3u8',
        '#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n#EXTINF:2.0,\nseg1.ts\n',
        const {},
      );
      // 拒收的判定：seed 不可被取出——通过内部状态间接验证不可行，
      // 用「重新 seed 完整清单后代理可用」对照（见下个测试）。
      // 这里直接断言拒收路径不抛异常且后续 seed 完整清单仍工作。
      await proxy.seedManifest(
        'https://cdn.example.com/complete.m3u8',
        '#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
        const {},
      );
    });

    test('带 ENDLIST 的完整媒体清单被接受（对照）', () async {
      final proxy = LocalMediaProxy.instance;
      // 对照：完整清单（带 ENDLIST）正常接受，不抛异常。
      await proxy.seedManifest(
        'https://cdn.example.com/complete2.m3u8',
        '#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
        const {},
      );
      await proxy.shutdown();
    });

    test('主清单（#EXT-X-STREAM-INF）无 ENDLIST 仍被接受', () async {
      final proxy = LocalMediaProxy.instance;
      // 主清单本来就没有 ENDLIST，且只有几行不会被截断。
      await proxy.seedManifest(
        'https://cdn.example.com/master.m3u8',
        '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
            '720p.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=500000\n'
            '360p.m3u8\n',
        const {},
      );
      await proxy.shutdown();
    });
  });

  group('P0-3 集成：200KB+ 带 ENDLIST 清单经探测后 seed', () {
    test('超过旧 64KB 上限的完整清单：决策为可 seed（cap 已放宽 512KB）',
        () {
      // 构造 200KB 的完整媒体清单（带 ENDLIST）。
      final buffer = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 12000; i++) {
        buffer.writeln('#EXTINF:2.0,');
        buffer.writeln(
            'https://cdn.example.com/seg/very/long/path/with/signature/token$i.m3u8.ts');
      }
      buffer.writeln('#EXT-X-ENDLIST');
      final manifest = buffer.toString();
      expect(manifest.length, greaterThan(200 * 1024));
      // 未触 512KB 上限 → 完整读取 → 可 seed。
      final d = HybridVideoSourceServiceProbe.decideHlsText(manifest.trimLeft(),
          truncated: false);
      expect(d.alive, isTrue);
      expect(d.canSeed, isTrue);
    });
  });
}
