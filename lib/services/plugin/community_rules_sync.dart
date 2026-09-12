import 'dart:convert';

import 'package:flutter_modular/flutter_modular.dart' show inject;
import 'package:miru/plugins/plugins.dart';
import 'package:miru/plugins/plugins_controller.dart';
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
        // v1.6.10 修复：静默同步只「更新已安装的规则」，不再静默安装
        // 本地没有的规则。旧逻辑（仅跳过日漫/失效名单）会让上游新增的
        // 任何规则（如 moonci：日漫向且搜索失效）在用户无感知的情况
        // 下被装进列表——与 rule_policy「由用户自行决定是否安装」的
        // 设计相悖。新规则的引入只剩两条正道：随包内置（assets/plugins，
        // 存量用户经启动时的内置规则刷新获得）与用户在规则仓库手动安装。
        if (local == null) {
          continue;
        }
        // v1.6.6 修复：本地已修改的规则不做静默覆盖——此前版本升级是
        // 全字段整对象替换，用户在编辑器里改的 referer/UA/反爬配置
        // 被静默重置（「边看边下」等依赖自定义 referer 的场景会突然
        // 回到 403 且极难排查）。记日志提示远端有新版本未同步。
        if (local.localModified) {
          MiruLogger().i(
            'CommunityRules: skip locally modified rule ${local.name} '
            '(remote version $remoteVersion available)',
          );
          continue;
        }
        if (!_remoteIsNewer(local.version, remoteVersion)) {
          continue;
        }

        final plugin = await _fetchRule(name);
        if (plugin == null) continue;
        try {
          await controller.updatePlugin(plugin, localModified: false);
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
