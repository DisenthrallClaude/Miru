import 'dart:async';

import 'package:miru/modules/search/plugin_search_module.dart';
import 'package:miru/pages/info/info_controller.dart';
import 'package:miru/plugins/plugins.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/plugin/plugin_health.dart';
import 'package:miru/services/plugin/rule_engine_models.dart';
import 'package:miru/utils/async_session.dart';

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
  });

  final InfoController infoController;
  final PluginsController pluginsController;
  final RuleCancelToken _cancelToken = RuleCancelToken();

  /// Per-plugin sessions so a replacement query (alias/manual search)
  /// invalidates the write-back of the still-running previous one.
  final Map<String, AsyncSessionOwner> _querySessions = {};
  bool _isCancelled = false;

  Future<void> querySource(String keyword, String pluginName) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName) {
        infoController.pluginSearchResponseList.removeWhere(
          (response) => response.pluginName == pluginName,
        );
        infoController.pluginSearchStatus[pluginName] =
            PluginSearchStatus.pending;
        await _queryPlugin(plugin, keyword);
        return;
      }
    }
  }

  /// Publishes the result page harvested by the captcha webview, skipping
  /// one network round trip. Returns false when the HTML does not parse
  /// into results; callers should fall back to [querySource].
  bool applyHarvestedSearchResult(String pluginName, String html) {
    if (_isCancelled) return false;
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName) continue;
      final result = plugin.parseHarvestedSearch(html);
      if (result == null) return false;
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(pluginName);
      infoController.pluginSearchResponseList.add(result);
      return true;
    }
    return false;
  }

  Future<void> queryAllSource(String keyword) async {
    infoController.pluginSearchResponseList.clear();
    infoController.pluginSearchStatus.clear();

    final plugins = List<Plugin>.of(pluginsController.pluginList);
    for (final plugin in plugins) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.pending;
    }
    await _queryPluginsWithLimit(plugins, keyword);
  }

  /// 全量搜索按固定并发分批执行；几十条规则同时发起请求
  /// 容易触发站点风控并拖垮弱网设备。
  Future<void> _queryPluginsWithLimit(
    List<Plugin> plugins,
    String keyword,
  ) async {
    const concurrencyLimit = 4;
    var nextIndex = 0;
    Future<void> worker() async {
      while (!_isCancelled && nextIndex < plugins.length) {
        final plugin = plugins[nextIndex++];
        await _queryPlugin(plugin, keyword);
      }
    }

    final workerCount =
        plugins.length < concurrencyLimit ? plugins.length : concurrencyLimit;
    if (workerCount == 0) return;
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _queryPlugin(Plugin plugin, String keyword) async {
    if (_isCancelled) return;
    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();
    try {
      final result = await plugin.queryBangumi(
        keyword,
        shouldRethrow: true,
        cancelToken: _cancelToken,
      );
      if (_isCancelled || session.isStale) return;
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.success;
      if (result.data.isNotEmpty) {
        pluginsController.validityTracker.markSearchValid(plugin.name);
        unawaited(PluginHealthTracker.instance.recordSuccess(plugin.name));
      }
      infoController.pluginSearchResponseList.add(result);
    } catch (error) {
      if (_isCancelled || session.isStale) return;
      _handleSearchError(plugin, error);
    }
  }

  void _handleSearchError(Plugin plugin, Object error) {
    if (error is CaptchaRequiredException) {
      MiruLogger().i(
        'PluginSearchService: captcha required for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.captcha;
      return;
    }
    if (error is NoResultException) {
      MiruLogger().i(
        'PluginSearchService: no results for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.noResult;
      return;
    }
    final name = error is SearchErrorException ? error.pluginName : plugin.name;
    MiruLogger().w('PluginSearchService: search error for $name');
    infoController.pluginSearchStatus[name] = PluginSearchStatus.error;
    // 真实的请求/解析故障计入健康档案；「无结果」「需验证」不算。
    unawaited(PluginHealthTracker.instance.recordFailure(name));
  }

  void cancel() {
    _isCancelled = true;
    _cancelToken.cancel();
  }
}
