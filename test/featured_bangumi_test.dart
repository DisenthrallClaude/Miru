import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/featured_bangumi.dart';

void main() {
  group('置顶国漫清单', () {
    test('清单非空且 id 无重复', () {
      expect(kFeaturedBangumiIds, isNotEmpty);
      expect(kFeaturedBangumiIds.toSet().length, kFeaturedBangumiIds.length,
          reason: '置顶 id 不应重复，否则首页会出现重复卡片');
    });

    test('id 与关键字一一对应', () {
      expect(kFeaturedBangumiKeywords.length, kFeaturedBangumiIds.length);
    });

    test('产品指定的前十顺序保持不变', () {
      const expected = [
        '斗破苍穹',
        '完美世界',
        '凡人修仙传',
        '仙逆',
        '剑来',
        '沧元图',
        '吞噬星空',
        '一人之下',
        '遮天',
        '斗罗大陆',
      ];
      expect(kFeaturedBangumiKeywords.take(10).toList(), expected);
    });

    test('featuredRankOfName 能匹配续作/分季命名', () {
      // 清单里存的是「凡人修仙传」，实际条目名常带季数后缀
      expect(featuredRankOfName('凡人修仙传 第四季'), 2);
      expect(featuredRankOfName('斗破苍穹 年番'), 0);
      expect(featuredRankOfName('某部不在清单里的番'), -1);
    });

    test('featuredRankOfId 按 id 精确匹配', () {
      expect(featuredRankOfId(kFeaturedBangumiIds.first), 0);
      expect(featuredRankOfId(-1), -1);
    });

    test('置顶项排在非置顶项之前，且保持清单顺序', () {
      // 复刻 timeline_controller 的复合比较逻辑
      int rank(String name) => featuredRankOfName(name);
      int compare(String a, String b) {
        final ra = rank(a);
        final rb = rank(b);
        if (ra != -1 || rb != -1) {
          if (ra == -1) return 1;
          if (rb == -1) return -1;
          if (ra != rb) return ra.compareTo(rb);
        }
        return 0;
      }

      final list = ['某冷门番', '斗罗大陆', '另一部冷门番', '斗破苍穹', '剑来'];
      list.sort(compare);
      expect(list.take(3).toList(), ['斗破苍穹', '剑来', '斗罗大陆']);
    });
  });
}
