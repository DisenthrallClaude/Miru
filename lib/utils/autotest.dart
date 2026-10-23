import 'dart:async';
import 'dart:io';


import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/navigation.dart';
import 'package:miru/pages/video/video_playback_args.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/update/auto_updater.dart';

/// CI/模拟器自动化播放自测（仅在构建时 `--dart-define=MIRU_AUTOTEST=...`
/// 注入时启用；正式发布包为空字符串，零行为变化）。
///
/// 格式：`规则名|关键词`，例如 `FQDM|凡人修仙传`。运行时优先读取系统属性
/// `debug.miru.autotest`（CI 逐源切换无需重编译），为空时用编译期值。
/// 启动完成后自动：该规则搜索 → 取首个匹配结果 → 选集 → 直接打开
/// 播放页第 1 集。全过程打 `MIRU_AUTOTEST` 前缀日志（logcat 可 grep）。
const String kMiruAutotest = String.fromEnvironment('MIRU_AUTOTEST');

bool get isAutotestBuild => kMiruAutotest.isNotEmpty;

Future<void> runAutotest(PluginsController pluginsController) async {
  if (!isAutotestBuild) return;
  var spec = kMiruAutotest;
  try {
    // CI 用 `adb shell setprop debug.miru.autotest '规则|关键词'` 逐源切换
    // （Android 11 起 adb 无法写入应用私有外部目录）。
    final r = await Process.run('getprop', ['debug.miru.autotest']);
    final text = (r.stdout as String? ?? '').trim();
    if (text.contains('|')) spec = text;
  } catch (_) {}
  final parts = spec.split('|');
  final pluginName = parts.first.trim();
  final keyword = parts.length > 1 ? parts[1].trim() : '凡人修仙传';
  void log(String m) => MiruLogger().i('MIRU_AUTOTEST $m');
  // v1.8.1：`update|demo` —— CI 验证应用内更新下载（把当前版本视作 0.0.1，
  // 弹出 releases/latest 的更新弹窗，由 CI 点「立即更新」走真实镜像下载）。
  if (pluginName == 'update') {
    await Future<void>.delayed(const Duration(seconds: 4));
    log('update-demo start');
    try {
      await AutoUpdater().debugShowUpdateForAutotest();
      log('update-demo dialog shown');
    } catch (e) {
      log('update-demo failed $e');
    }
    return;
  }
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
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      log('no-navigator-context');
      return;
    }
    // ignore: use_build_context_synchronously
    unawaited(ctx.pushNamed(
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
