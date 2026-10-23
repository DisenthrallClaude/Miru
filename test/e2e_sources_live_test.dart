@Tags(['live'])
library;

// 逐源端到端实测（v2 诊断用）：
//   规则引擎搜索 → 选第一个匹配结果 → 选集（前 2 条线路的第 1 集）→
//   App 真实快解层（FastVideoSourceResolver）+ 云端层（CloudVideoSourceResolver）
//   → 输出候选直链 + App 实际会传给 mpv 的 headers 到 JSON，
//   再由 tool/e2e_play.sh 用 mpv/ffprobe 真实拉流验证。
//
// 运行：
//   E2E_KEYWORD=凡人修仙传 E2E_OUT=/tmp/e2e/result.json \
//   flutter test test/e2e_sources_live_test.dart -r expanded
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:miru/plugins/plugins.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:miru/services/video_source/cloud_video_source_resolver.dart';
import 'package:miru/services/video_source/fast_video_source_resolver.dart';
import 'package:miru/utils/episode_url.dart';
import 'package:miru/utils/http_headers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async => '/tmp/miru_e2e');

  test('e2e sources', () async {
    await Hive.initFlutter('/tmp/miru_e2e/hive');
    await GStorage.init();
    final keywords = (Platform.environment['E2E_KEYWORD'] ?? '凡人修仙传')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final outPath = Platform.environment['E2E_OUT'] ?? '/tmp/e2e/result.json';
    final only = Platform.environment['E2E_ONLY'];
    final dirPath = Platform.environment['E2E_RULES'] ?? 'assets/plugins';
    final files = Directory(dirPath)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .where((f) => only == null || f.path.contains(only))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final sessionUA = getSessionUA();
    final rows = <Map<String, dynamic>>[];

    for (final file in files) {
      final row = <String, dynamic>{'file': file.path.split('/').last};
      rows.add(row);
      final sw = Stopwatch()..start();
      try {
        final plugin = Plugin.fromJson(jsonDecode(file.readAsStringSync()));
        row['name'] = plugin.name;
        row['baseUrl'] = plugin.baseUrl;
        dynamic target;
        String? usedKeyword;
        for (final kw in keywords) {
          try {
            final trace = await plugin
                .traceSearch(kw)
                .timeout(const Duration(seconds: 25));
            final results = trace.response.data;
            if (results.isEmpty) continue;
            target = results.firstWhere((e) => e.name.contains(kw),
                orElse: () => results.first);
            usedKeyword = kw;
            row['searchCount'] = results.length;
            break;
          } catch (e) {
            row['searchError'] = e.toString().split('\n').first;
          }
        }
        row['searchMs'] = sw.elapsedMilliseconds;
        if (target == null) {
          row['stage'] = 'search';
          continue;
        }
        row['keyword'] = usedKeyword;
        row['title'] = target.name;
        row['detail'] = target.src;
        final chapterTrace = await plugin
            .traceChapters(target.src)
            .timeout(const Duration(seconds: 25));
        final roads = chapterTrace.roads;
        row['roads'] = roads.length;
        row['chapterMs'] = sw.elapsedMilliseconds;
        if (roads.isEmpty) {
          row['stage'] = 'chapters';
          continue;
        }
        final eps = <Map<String, dynamic>>[];
        for (final road in roads.take(2)) {
          if (road.data.isEmpty) continue;
          final epUrl = normalizeEpisodeUrl(plugin.baseUrl, road.data.first);
          final ep = <String, dynamic>{
            'road': road.name,
            'episodeUrl': epUrl,
          };
          eps.add(ep);
          // App 构造的播放头（video_controller._resolveWithVideoSourceService）
          final playbackHeaders = <String, String>{
            'user-agent':
                plugin.userAgent.isEmpty ? sessionUA : plugin.userAgent,
            if (plugin.referer.isNotEmpty) 'referer': plugin.referer,
          };
          ep['pluginHeaders'] = playbackHeaders;
          final fsw = Stopwatch()..start();
          try {
            final report = await FastVideoSourceResolver.instance
                .resolveCandidates(epUrl,
                    userAgent: playbackHeaders['user-agent'],
                    referer: playbackHeaders['referer'] ?? epUrl)
                .timeout(const Duration(seconds: 20));
            ep['fastMs'] = fsw.elapsedMilliseconds;
            ep['fastFailure'] = report.failure?.name;
            ep['fast'] = [
              for (final c in report.candidates)
                {
                  'url': c.url,
                  'referer': c.referer,
                  'strategy': c.strategy.name,
                  'format': c.format.name,
                  // mpv 实际收到的头：mergePlaybackHeaders(插件头, 解析层头)
                  'mpvHeaders': mergePlaybackHeaders(playbackHeaders,
                      c.toVideoSource().playbackHeaders),
                }
            ];
          } catch (e) {
            ep['fastError'] = e.toString().split('\n').first;
          }
          final csw = Stopwatch()..start();
          try {
            final cr = await CloudVideoSourceResolver.instance
                .resolveWithReport(epUrl,
                    userAgent: playbackHeaders['user-agent'],
                    referer: playbackHeaders['referer'])
                .timeout(const Duration(seconds: 15));
            ep['cloudMs'] = csw.elapsedMilliseconds;
            ep['cloudFailure'] = cr.failureClass;
            if (cr.source != null) {
              ep['cloud'] = {
                'url': cr.source!.url,
                'mpvHeaders': mergePlaybackHeaders(
                    playbackHeaders, cr.source!.playbackHeaders),
              };
            }
          } catch (e) {
            ep['cloudError'] = e.toString().split('\n').first;
          }
        }
        row['episodes'] = eps;
        row['stage'] = 'resolved';
      } catch (e) {
        row['error'] = e.toString().split('\n').first;
      }
      row['totalMs'] = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('E2E ${jsonEncode(row)}');
    }
    final out = File(outPath);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rows));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
