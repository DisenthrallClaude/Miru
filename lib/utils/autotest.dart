import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/pages/video/video_playback_args.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/services/logging/logger.dart';

/// CI/模拟器自动化播放自测（仅在构建时 `--dart-define=MIRU_AUTOTEST=...`
/// 注入时启用；正式发布包为空字符串，零行为变化）。
///
/// 格式：`规则名|关键词`，例如 `FQDM|凡人修仙传`。运行时优先读取
/// `<外部存储应用目录>/autotest.txt`（CI 用 adb 写入，可逐源切换而无需
/// 重新编译），不存在时用编译期值。
/// 启动完成后自动：该规则搜索 → 取首个匹配结果 → 选集 → 直接打开
/// 播放页第 1 集。全过程打 `MIRU_AUTOTEST` 前缀日志（logcat 可 grep）。
const String kMiruAutotest = String.fromEnvironment('MIRU_AUTOTEST');

bool get isAutotestBuild => kMiruAutotest.isNotEmpty;

Future<void> runAutotest(PluginsController pluginsController) async {
  if (!isAutotestBuild) return;
  var spec = kMiruAutotest;
  try {
    final dir = await getExternalStorageDirectory();
    final f = File('${dir?.path}/autotest.txt');
    if (dir != null && await f.exists()) {
      final text = (await f.readAsString()).trim();
      if (text.contains('|')) spec = text;
    }
  } catch (_) {}
  final parts = spec.split('|');
  final pluginName = parts.first.trim();
  final keyword = parts.length > 1 ? parts[1].trim() : '凡人修仙传';
  void log(String m) => MiruLogger().i('MIRU_AUTOTEST $m');
  try {
    await Future<void>.delayed(const Duration(seconds: 3));
    final plugin = pluginsController.pluginList
        .where((p) => p.name.toLowerCase() == pluginName.toLowerCase())
        .firstOrNull;
    if (plugin == null) {
      log('plugin-not-found $pluginName '
          '(have: ${pluginsController.pluginList.map((p) => p.name).join(',')})');
      return;
    }
    log('search ${plugin.name} "$keyword"');
    final result = await plugin
        .queryBangumi(keyword)
        .timeout(const Duration(seconds: 30));
    if (result.data.isEmpty) {
      log('search-empty');
      return;
    }
    final item = result.data.firstWhere((e) => e.name.contains(keyword),
        orElse: () => result.data.first);
    log('search-hit ${item.name} ${item.src}');
    final roads = await plugin
        .queryChapterRoads(item.src)
        .timeout(const Duration(seconds: 30));
    log('roads ${roads.length} first=${roads.isEmpty ? 0 : roads.first.data.length}');
    if (roads.isEmpty) return;
    final bangumi = BangumiItem(
      id: 0,
      type: 2,
      name: item.name,
      nameCn: item.name,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: const {'large': '', 'common': '', 'medium': '', 'small': '', 'grid': ''},
      tags: const [],
      alias: const [],
      ratingScore: 0,
      votes: 0,
      votesCount: const [],
      info: '',
    );
    log('open-video');
    unawaited(Modular.to.pushNamed(
      '/video/',
      arguments: OnlineVideoPlaybackArgs(
        bangumiItem: bangumi,
        plugin: plugin,
        title: item.name,
        src: item.src,
        roads: roads,
      ),
    ));
  } catch (e, s) {
    MiruLogger().e('MIRU_AUTOTEST failed', error: e, stackTrace: s);
  }
}
