import 'dart:convert';

import 'package:flutter_modular/flutter_modular.dart' show inject;
import 'package:miru/plugins/plugins.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/plugins/rule_policy.dart';
import 'package:miru/request/clients/rules_repo_client.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/utils/version.dart';

/// 社区规则仓库静默同步。
///
/// 数据源是 Kazumi 社区官方维护的规则仓库（Predidit/KazumiRules）：
/// 每条规则一个 JSON 文件，`index.json` 汇总名称与版本号。
/// 相比内置打包规则，社区仓库由多位贡献者实时跟进站点改版，
/// 域名迁移后通常当天就有新版本 —— 自动同步让用户无感跟上。
///
/// 国内可达性：raw.githubusercontent.com 直连不稳定，
/// 因此按 jsDelivr 多节点优先、raw 兜底的顺序逐级回退。
class CommunityRulesSync {
  CommunityRulesSync._();

  /// 镜像前缀，按国内可达性排序；{file} 会替换为目标文件名。
  static const List<String> _mirrors = [
    'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/',
    'https://fastly.jsdelivr.net/gh/Predidit/KazumiRules@main/',
    'https://testingcf.jsdelivr.net/gh/Predidit/KazumiRules@main/',
    'https://raw.githubusercontent.com/Predidit/KazumiRules/main/',
  ];

  /// 同步一次社区规则。返回成功更新的规则数；任何失败都只记日志，
  /// 启动路径上的静默任务绝不能打扰用户。
  static Future<int> sync() async {
    try {
      final index = await _fetchIndex();
      if (index.isEmpty) return 0;

      final controller = inject<PluginsController>();
      final localByName = <String, Plugin>{
        for (final plugin in controller.pluginList)
          plugin.name.toLowerCase(): plugin,
      };

      var updated = 0;
      for (final entry in index) {
        final name = entry['name']?.toString();
        final remoteVersion = entry['version']?.toString() ?? '';
        if (name == null || name.isEmpty || remoteVersion.isEmpty) continue;

        final local = localByName[name.toLowerCase()];
        // 未安装的日漫/失效规则不做静默安装：这些规则只应经由
        // 设置 → 规则管理 → 规则仓库 由用户主动决定是否安装。
        // 用户已经手动装上的规则则照常跟进版本更新。
        if (local == null && shouldSkipAutoInstall(name)) {
          continue;
        }
        if (local != null && !_remoteIsNewer(local.version, remoteVersion)) {
          continue;
        }

        final plugin = await _fetchRule(name);
        if (plugin == null) continue;
        try {
          await controller.updatePlugin(plugin);
          updated++;
          MiruLogger().i(
            'CommunityRules: $local -> $remoteVersion (${plugin.name})',
          );
        } catch (error, stackTrace) {
          MiruLogger().w(
            'CommunityRules: failed to persist ${plugin.name}',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      if (updated > 0) {
        MiruLogger().i('CommunityRules: synced $updated rule(s)');
      }
      return updated;
    } catch (error, stackTrace) {
      MiruLogger().w(
        'CommunityRules: sync failed',
        error: error,
        stackTrace: stackTrace,
      );
      return 0;
    }
  }

  static bool _remoteIsNewer(String localVersion, String remoteVersion) {
    try {
      return needUpdate(localVersion, remoteVersion);
    } catch (_) {
      return localVersion != remoteVersion;
    }
  }

  /// 拉取并解析索引；全部镜像失败时抛出，由 [sync] 统一兜底。
  static Future<List<dynamic>> _fetchIndex() async {
    Object? lastError;
    for (final mirror in _mirrors) {
      try {
        final text = await RulesRepoClient.instance.getText('$mirror/index.json');
        final decoded = jsonDecode(text);
        if (decoded is List) return decoded;
        lastError = FormatException('community rules index is not a list');
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('all community rule mirrors failed');
  }

  /// 下载单条规则；解析失败或与请求名称不符时返回 null 跳过该条。
  static Future<Plugin?> _fetchRule(String name) async {
    for (final mirror in _mirrors) {
      try {
        final text =
            await RulesRepoClient.instance.getText('$mirror/$name.json');
        final plugin = Plugin.fromJson(jsonDecode(text));
        if (plugin.name.isNotEmpty && plugin.name.toLowerCase() == name.toLowerCase()) {
          return plugin;
        }
        MiruLogger().w(
          'CommunityRules: rejected mismatched payload $name != ${plugin.name}',
        );
        return null;
      } catch (_) {
        // 换下一个镜像继续试。
      }
    }
    return null;
  }
}
