import 'package:miru/plugins/plugins.dart';

abstract final class BundledRulePriority {
  /// v1.8.0 内置规则优先级（小在前）。未列出的为 [defaultPriority]。
  /// jciyuan / dmjd：rules_research 大陆 17ce 拨测 ≥170/177、178/178 节点可达，
  /// 海外全链路验证通过 → 靠前；dmttang / milimili：CF 前置、大陆部分可达 → 靠后。
  static const Map<String, int> table = {
    'jciyuan': 0,
    'dmjd': 1,
    'dmttang': 90,
    'milimili': 91,
  };
  static const int defaultPriority = 50;

  static int of(String name) =>
      table[name.toLowerCase()] ?? defaultPriority;

  /// 稳定排序（同优先级保持 asset 清单原序）。
  static void sort(List<Plugin> bundled) {
    final indexed = [for (var i = 0; i < bundled.length; i++) (i, bundled[i])];
    indexed.sort((a, b) {
      final c = of(a.$2.name)
          .compareTo(of(b.$2.name));
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    bundled
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }

  /// 新内置规则的插入位置：高优先级（< 默认）插到所有「优先级不高于它」
  /// 的规则之前（老用户已有顺序不变，只是新规则排进前面）；其余追加末尾。
  static void insertNew(List<Plugin> list, Plugin plugin) {
    final p = of(plugin.name);
    if (p >= defaultPriority) {
      list.add(plugin);
      return;
    }
    var at = 0;
    while (at < list.length && of(list[at].name) <= p) {
      at++;
    }
    list.insert(at, plugin);
  }

}
