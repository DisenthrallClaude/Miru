/// v1.8.1：首页分类（国漫）定义。
///
/// **根因**（v1.8.0 及以前）：分类走 Bangumi 搜索的 `filter.tag`，它匹配的是
/// **用户自由标注的标签**——只要有一个人给条目打过「日常」，条目就会命中。
/// 实测「中国 + 日常」热度第一是《刺客伍六七》（「日常」票数 0，排不进前 8 个标签），
/// 《罗小黑战记》也因 39 人打了「日常」而混入；且列表沿用日番标签
/// （后宫/轻改/偶像/异世界/百合…），国漫在这些标签下 0~5 部甚至为空。
///
/// **修复**：改用 Bangumi 维基维护的**公共标签 `filter.meta_tags`**（条目编辑审核过的
/// 题材/来源/形式），产地同样用 meta 标签「中国」。只保留国漫下条目数足够的题材
/// （2026-10-23 实测数量写在注释里），每个分类的内容与其名字一一对应。
class AnimeCategory {
  const AnimeCategory(this.label, this.metaTag, {this.count = 0});

  /// 展示名。
  final String label;

  /// 对应的 Bangumi 公共标签（meta_tags）。
  final String metaTag;

  /// 实测条目数（中国 + 该标签，仅供排序参考）。
  final int count;
}

/// 产地公共标签。
const String kRegionMetaTag = '中国';

const List<AnimeCategory> kAnimeCategories = [
  AnimeCategory('玄幻', '玄幻', count: 283),
  AnimeCategory('武侠', '武侠', count: 90),
  AnimeCategory('奇幻', '奇幻', count: 292),
  AnimeCategory('战斗', '战斗', count: 254),
  AnimeCategory('科幻', '科幻', count: 123),
  AnimeCategory('恋爱', '恋爱', count: 100),
  // Bangumi 公共标签里没有「搞笑」，对应的是「喜剧」
  AnimeCategory('搞笑', '喜剧', count: 78),
  AnimeCategory('日常', '日常', count: 89),
  AnimeCategory('冒险', '冒险', count: 72),
  AnimeCategory('穿越', '穿越', count: 52),
  AnimeCategory('历史', '历史', count: 50),
  AnimeCategory('校园', '校园', count: 39),
  AnimeCategory('萌系', '萌系', count: 36),
  AnimeCategory('悬疑', '悬疑', count: 35),
  AnimeCategory('运动', '运动', count: 29),
  AnimeCategory('原创', '原创', count: 553),
  AnimeCategory('小说改', '小说改', count: 578),
  AnimeCategory('漫画改', '漫画改', count: 368),
  AnimeCategory('游戏改', '游戏改', count: 85),
  AnimeCategory('剧场版', '剧场版', count: 935),
];

/// 按展示名查分类；找不到（旧版本残留的标签名）返回 null。
AnimeCategory? categoryByLabel(String label) {
  for (final c in kAnimeCategories) {
    if (c.label == label) return c;
  }
  return null;
}

/// 分类请求用的 meta_tags 过滤：产地 + 分类公共标签。
List<String> categoryMetaTags(String label) {
  final c = categoryByLabel(label);
  return [kRegionMetaTag, c?.metaTag ?? label];
}
