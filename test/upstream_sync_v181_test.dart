// v1.8.0 上游 Kazumi 2.3.7–2.4.2 精选采纳的回归锁。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/plugins/api_rule_config.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/services/plugin/api_rule_strategy.dart';

void main() {
  group('searchApiConfig.sourceTemplate（上游 ff85947，规则 API 9）', () {
    const raw =
        '{"code":1,"list":[{"id":2971,"name":"凡人修仙传"},{"id":"a b","name":"斗破"}]}';

    test('裸 id 按模板拼出详情页（KazumiRules LMM 2.3 形态）', () {
      final config = ApiSearchConfig.fromJson({
        'request': {'method': 'GET', 'url': 'https://x/index.php/ajax/suggest'},
        'listPath': r'$.list[*]',
        'namePath': r'$.name',
        'sourcePath': r'$.id',
        'sourceTemplate':
            'https://www.lmm85.com/index.php/vod/detail/id/@source.html',
      });
      final result = const ApiRuleStrategy().parseSearch(raw, config);
      expect(result.items.map((e) => e.src), [
        'https://www.lmm85.com/index.php/vod/detail/id/2971.html',
        'https://www.lmm85.com/index.php/vod/detail/id/a%20b.html',
      ]);
    });

    test('空模板保持原值；序列化往返不丢字段', () {
      final config = ApiSearchConfig.fromJson({
        'listPath': r'$.list[*]',
        'namePath': r'$.name',
        'sourcePath': r'$.id',
        'sourceTemplate': '',
      });
      final result = const ApiRuleStrategy().parseSearch(raw, config);
      expect(result.items.first.src, '2971');
      expect(config.toJson().containsKey('sourceTemplate'), isFalse);

      final withTpl = ApiSearchConfig(sourceTemplate: ' https://s/GV@source ');
      final back = ApiSearchConfig.fromJson(
          jsonDecode(jsonEncode(withTpl.toJson())) as Map<String, dynamic>);
      expect(back.sourceTemplate, 'https://s/GV@source');
    });

    test('模板不含 @source 视为规则错误', () {
      final config = ApiSearchConfig(sourceTemplate: 'https://s/detail');
      expect(() => const ApiRuleStrategy().validateSearchConfig(config),
          throwsA(isA<ApiRuleFormatException>()));
    });

    test('App 规则 API 级别 ≥ 9，可安装 KazumiRules 新版规则', () {
      expect(ApiEndpoints.apiLevel, greaterThanOrEqualTo(9));
    });
  });

  group('规则仓库镜像链（参考上游 2.4.1/2.4.2）', () {
    test('镜像链以 gh-proxy 开头、不含 gitcode（418 反爬）、末尾保留 jsDelivr', () {
      final mirrors = ApiEndpoints.pluginShopMirrors;
      expect(mirrors.first, startsWith('https://gh-proxy.org/'));
      expect(mirrors.any((m) => m.contains('gitcode')), isFalse);
      expect(mirrors.last, ApiEndpoints.pluginShopMirror);
      for (final m in mirrors) {
        expect(m, endsWith('/'));
      }
    });
  });
}
