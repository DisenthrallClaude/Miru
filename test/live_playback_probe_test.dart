@Tags(['live'])
library;

// 播放链路真实探测：模拟 app 在真机上的完整播放流程。
//
// 链路: 规则引擎搜索 → 详情 → 线路/集数 → 播放页 HTML →
//       提取 m3u8 (decodeVideoSource + player_aaaa) →
//       带 app 同款 headers 请求 m3u8 → 解析分片 → 请求首个 ts 分片。
//
// 运行: ~/dev/flutter/bin/flutter test test/live_playback_probe_test.dart \
//         --plain-name "live playback probe" -r expanded
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/plugins/plugins.dart';
import 'package:miru/utils/http_headers.dart';
import 'package:miru/utils/media.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/services/storage/storage.dart';

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
        return '/tmp/miru_probe_test';
    }
    return null;
  });

  final dir = Directory('assets/plugins');

  test('live playback probe', () async {
    await Hive.initFlutter('/tmp/miru_probe_test/hive');
    await GStorage.init();

    // 模拟一次 app 会话的固定 UA（app 内 getSessionUA 的行为）
    final sessionUA = getRandomUA();

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (code) => true, // 4xx/5xx 也拿到 body 以便诊断
    ));

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final report = <String, Map<String, dynamic>>{};
    final keyword = '斗破苍穹';

    for (final file in files) {
      final name = file.path.split('/').last;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(file.readAsStringSync());
      } catch (_) {
        continue;
      }
      final row = <String, dynamic>{};
      report[name] = row;
      try {
        final plugin = Plugin.fromJson(json);
        row['name'] = plugin.name;
        final trace = await plugin
            .traceSearch(keyword)
            .timeout(const Duration(seconds: 30));
        final results = trace.response.data;
        if (results.isEmpty) {
          row['search'] = 'NO_RESULT';
          continue;
        }
        row['search'] = results.length;
        final target = results.firstWhere(
          (e) => e.name.contains(keyword),
          orElse: () => results.first,
        );
        final chapterTrace = await plugin
            .traceChapters(target.src)
            .timeout(const Duration(seconds: 30));
        final roads = chapterTrace.roads;
        row['roads'] = roads.length;
        if (roads.isEmpty) continue;
        final roadList = roads.take(3).toList();
        final roadReports = <String>[];
        for (final road in roadList) {
          final ep = road.data.isEmpty ? null : road.data.first;
          if (ep == null) {
            roadReports.add('${road.name}:EMPTY');
            continue;
          }
          roadReports.add(
              await probeRoad(plugin, ep, sessionUA, dio, row, road.name));
        }
        row['roadProbe'] = roadReports;
      } catch (e) {
        row['error'] = e.toString().split('\n').first;
      }
    }

    // 汇总
    for (final e in report.entries) {
      final v = e.value;
      final buf = StringBuffer();
      buf.write('${e.key} [${v['name'] ?? '?'}] ');
      buf.write('search=${v['search']} roads=${v['roads'] ?? '-'} ');
      if (v['roadProbe'] != null) {
        for (final r in (v['roadProbe'] as List)) {
          buf.write('\n    $r');
        }
      }
      if (v['error'] != null) buf.write(' ERR=${v['error']}');
      // ignore: avoid_print
      print(buf);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}


/// 探测单条线路：播放页 → m3u8 → ts 分片
Future<String> probeRoad(
    Plugin plugin, String episodeUrl, String sessionUA, Dio dio,
    Map<String, dynamic> row, String roadName) async {
  // 模拟 app 的 normalizeEpisodeUrl + Uri.resolve 相对路径解析
  final fullUrl = Uri.parse(plugin.baseUrl).resolve(episodeUrl).toString();
  // ignore: avoid_print
  print('    [$roadName] page: $episodeUrl -> $fullUrl');

  try {
    // 1) 拉播放页 HTML（模拟 webview 加载）
    final pageHeaders = <String, String>{
      'user-agent': plugin.userAgent.isEmpty ? sessionUA : plugin.userAgent,
      'referer': plugin.referer.isNotEmpty ? plugin.referer : plugin.baseUrl,
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    };
    final pageResp = await dio.get<String>(fullUrl,
        options: Options(headers: pageHeaders, responseType: ResponseType.plain));
    if (pageResp.statusCode != 200) {
      return '$roadName:PAGE_${pageResp.statusCode}';
    }
    final html = pageResp.data ?? '';

    // 2) 提取 m3u8：先 player_aaaa（MacCMS），再 decodeVideoSource 全文提取
    String? m3u8;
    final playerAaaa = RegExp(
            r'player_aaaa\s*=\s*(\{[^}]+\})')
        .firstMatch(html);
    if (playerAaaa != null) {
      try {
        final Map<String, dynamic> pj = jsonDecode(playerAaaa.group(1)!);
        final u = pj['url']?.toString() ?? '';
        if (u.isNotEmpty) m3u8 = decodeVideoSource(u);
      } catch (_) {}
    }
    m3u8 ??= decodeVideoSource(html); // 全文提取（含协议相对地址）
    // ignore: avoid_print
    print('    [$roadName] extracted: $m3u8');
    // 提前暴露非法 % 编码：app 内同样的字符串会交给 mpv
    try {
      Uri.parse(m3u8);
    } catch (e) {
      return '$roadName:BAD_URI(${e.toString().split('\n').first})';
    }
    if (!m3u8.contains('m3u8') && !m3u8.contains('.mp4')) {
      return '$roadName:NO_MEDIA_LINK(html:${html.length}b)';
    }
    // 相对路径补全
    if (!m3u8.startsWith('http')) {
      final origin = Uri.parse(fullUrl).origin;
      m3u8 = m3u8.startsWith('/')
          ? '$origin$m3u8'
          : '$origin/${Uri.parse(fullUrl).pathSegments.isNotEmpty ? Uri.parse(fullUrl).pathSegments.sublist(0, Uri.parse(fullUrl).pathSegments.length - 1).join('/') : ''}/$m3u8';
    }

    // 3) 模拟 mpv 请求 m3u8（app 实际传给 mpv 的 headers）
    final mediaHeaders = <String, String>{
      'user-agent': plugin.userAgent.isEmpty ? sessionUA : plugin.userAgent,
      if (plugin.referer.isNotEmpty) 'referer': plugin.referer,
    };
    final m3u8Resp = await dio.get<String>(m3u8,
        options: Options(headers: mediaHeaders, responseType: ResponseType.plain));
    if (m3u8Resp.statusCode != 200) {
      return '$roadName:M3U8_${m3u8Resp.statusCode}(${_short(m3u8)})';
    }
    final body = m3u8Resp.data ?? '';
    if (!body.startsWith('#EXTM3U')) {
      return '$roadName:NOT_M3U8(${_short(m3u8)})';
    }

    // 4) 取首个分片请求（子 playlist 或 ts）
    final lines =
        body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    String? seg;
    for (final l in lines) {
      if (l.startsWith('#')) {
        if (l.startsWith('#EXT-X-KEY')) {
          final uri = RegExp(r'URI="([^"]+)"').firstMatch(l)?.group(1);
          if (uri != null) break; // 有 KEY 的先取 KEY 后面的媒体段也行, 简化: 取下一个非#行
          continue;
        }
        continue;
      }
      seg = l;
      break;
    }
    if (seg == null) return '$roadName:M3U8_NO_SEGMENT';
    if (!seg.startsWith('http')) {
      final u = Uri.parse(m3u8);
      seg = seg.startsWith('/')
          ? '${u.origin}$seg'
          : '${u.origin}/${u.pathSegments.isNotEmpty ? u.pathSegments.sublist(0, u.pathSegments.length - 1).join('/') : ''}/$seg';
    }
    final segResp = await dio.get<List<int>>(seg,
        options: Options(headers: mediaHeaders, responseType: ResponseType.bytes));
    if (segResp.statusCode != 200 && segResp.statusCode != 206) {
      return '$roadName:SEG_${segResp.statusCode}';
    }
    final size = segResp.data?.length ?? 0;
    return '$roadName:OK(m3u8 200+EXTM3U, seg ${size ~/ 1024}KB)';
  } catch (e, s) {
    return '$roadName:EXC(${e.toString().split('\n').first})'
        ' [at ${s.toString().split('\n').take(4).where((l) => l.contains('probe') || l.contains('dio') || l.contains('http')).join(' | ')}]';
  }
}

String _short(String s) =>
    s.length > 60 ? '${s.substring(0, 60)}...' : s;
