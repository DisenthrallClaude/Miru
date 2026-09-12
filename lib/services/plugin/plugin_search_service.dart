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

  /// 单条规则搜索的应用层超时。
  ///
  /// dio 只有连接 12s + 接收 12s（接收是数据间隔而非总时长）且幂等
  /// 重试一次，单条规则最坏 ~48s 才报错，慢规则会拖住整轮全量搜索的
  /// 进度条。这里给每条规则统一加上 10s 预算，超时计入健康失败。
  static const Duration perPluginTimeout = Duration(seconds: 10);

  /// Per-plugin sessions so a replacement query (alias/manual search)
  /// invalidates the write-back of the still-running previous one.
  final Map<String, AsyncSessionOwner> _querySessions = {};

  /// 在途请求的取消令牌：全局 cancel 或单条超时都能精确取消对应请求。
  final List<RuleCancelToken> _activeTokens = [];
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
    // v1.6.9（P1-9）：全量搜索改为增量覆盖——旧实现发起前先
    // clear() 整个结果列表，弱网下几十个插件要查十几秒，期间用户
    // 看着白屏列表等结果回来；现在旧结果保留占位，每个插件返回时
    // 原位替换自己的条目，失败的插件保留旧结果并打错误状态标记，
    // 「有总比没有强」。已被卸载的插件条目在发起前清掉（防止幽灵
    // 条目常驻）。
    final plugins = List<Plugin>.of(pluginsController.pluginList);
    final validNames = plugins.map((p) => p.name).toSet();
    infoController.pluginSearchResponseList.removeWhere(
      (response) => !validNames.contains(response.pluginName),
    );
    infoController.pluginSearchStatus.clear();
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
    final cancelToken = RuleCancelToken();
    _activeTokens.add(cancelToken);
    try {
      final result = await plugin
          .queryBangumi(
            keyword,
            shouldRethrow: true,
            cancelToken: cancelToken,
          )
          .timeout(perPluginTimeout);
      if (_isCancelled || session.isStale) return;
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.success;
      if (result.data.isNotEmpty) {
        pluginsController.validityTracker.markSearchValid(plugin.name);
        unawaited(PluginHealthTracker.instance.recordSuccess(plugin.name));
      }
      // v1.6.9（P1-9）：增量覆盖——替换本插件的旧条目而非追加，
      // 全量搜索期间旧结果仍占位展示。
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == plugin.name,
      );
      infoController.pluginSearchResponseList.add(result);
    } on TimeoutException {
      // 超时后取消底层请求，避免它继续占用连接打站点。
      cancelToken.cancel('search timeout');
      if (_isCancelled || session.isStale) return;
      MiruLogger().w(
        'PluginSearchService: search timeout for ${plugin.name}',
      );
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.error;
      unawaited(PluginHealthTracker.instance.recordFailure(plugin.name));
    } catch (error) {
      if (_isCancelled || session.isStale) return;
      _handleSearchError(plugin, error);
    } finally {
      _activeTokens.remove(cancelToken);
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
    for (final token in _activeTokens) {
      if (!token.isCancelled) token.cancel('search cancelled');
    }
    _activeTokens.clear();
  }
}
