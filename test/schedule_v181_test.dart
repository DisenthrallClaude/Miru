import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/request/apis/bangumi_api.dart';
import 'package:miru/request/apis/season_schedule.dart';
import 'package:miru/utils/anime_categories.dart';
import 'package:miru/utils/anime_season.dart';
import 'package:miru/utils/broadcast_schedule.dart';

/// v1.8.1：时间表更新日判定 + 首页分类映射。
/// fixtures/schedule_2026q4.json 是 2026-10-23 从 api.bgm.tv 抓的真实数据
/// （本季国漫 20 条、前 12 个月国漫 20 条、官方放送表 id→星期）。
void main() {
  group('parseBroadcastWeekdays', () {
    test('单日 / 多日 / 省略写法', () {
      expect(parseBroadcastWeekdays('星期四'), [4]);
      expect(parseBroadcastWeekdays('星期四、星期日'), [4, 7]);
      expect(parseBroadcastWeekdays('星期三、星期四、星期五'), [3, 4, 5]);
      expect(parseBroadcastWeekdays('星期日、一、二'), [1, 2, 7]);
      expect(parseBroadcastWeekdays('周六'), [6]);
      expect(parseBroadcastWeekdays('每周六 10:00'), [6]);
      expect(parseBroadcastWeekdays('礼拜天'), [7]);
    });
    test('改档取箭头后的最新档期，括号注释忽略', () {
      expect(parseBroadcastWeekdays('星期三→星期日（20话起）'), [7]);
      expect(parseBroadcastWeekdays('周二->周五(第3集起)'), [5]);
    });
    test('区间与每日', () {
      expect(parseBroadcastWeekdays('周一至周五'), [1, 2, 3, 4, 5]);
      expect(parseBroadcastWeekdays('星期五~星期一'), [1, 5, 6, 7]);
      expect(parseBroadcastWeekdays('每日更新'), [1, 2, 3, 4, 5, 6, 7]);
    });
    test('空 / 不定期 / 无关文字不产生误判', () {
      expect(parseBroadcastWeekdays(null), isEmpty);
      expect(parseBroadcastWeekdays(''), isEmpty);
      expect(parseBroadcastWeekdays('不定期'), isEmpty);
      expect(parseBroadcastWeekdays('一次性放送'), isEmpty);
    });
  });

  group('日历日解析与星期（与时区无关）', () {
    test('多种日期格式', () {
      expect(parseCalendarDate('2026-10-05'), DateTime(2026, 10, 5));
      expect(parseCalendarDate('2026年12月27日'), DateTime(2026, 12, 27));
      expect(parseCalendarDate('2026/1/3'), DateTime(2026, 1, 3));
      expect(parseCalendarDate('未定'), isNull);
    });
    test('星期按日历日计算：2026-10-05 是周一、2026-10-18 是周日', () {
      expect(weekdayOfDate('2026-10-05'), DateTime.monday);
      expect(weekdayOfDate('2026-10-18'), DateTime.sunday);
      // 带时间也只看日期部分（不做 UTC 换算，00:30 不会被挪到前一天）
      expect(weekdayOfDate('2026-10-05 00:30'), DateTime.monday);
    });
    test('季度窗口为纯日期字符串（秋季 = 09-01 ~ 12-01）', () {
      expect(AnimeSeason(DateTime(2026, 10, 23)).toSeasonStartAndEnd(),
          ['2026-09-01', '2026-12-01']);
    });
  });

  group('resolveBroadcastDays（真实条目）', () {
    late Map<String, dynamic> fx;
    late Map<int, int> official;
    Map<String, dynamic> byName(List list, String nameCn) =>
        Map<String, dynamic>.from(list.firstWhere((e) => e['name_cn'] == nameCn));

    setUpAll(() {
      fx = jsonDecode(File('test/fixtures/schedule_2026q4.json')
          .readAsStringSync()) as Map<String, dynamic>;
      official = (fx['official'] as Map)
          .map((k, v) => MapEntry(int.parse(k as String), v as int));
    });

    test('《大夏守墓人》首播周三，放送星期周三+周四 → 两天都有', () {
      final r = resolveBroadcastDays(byName(fx['season'], '大夏守墓人'),
          official: official);
      expect(r.weekdays, [3, 4]);
      expect(r.source, 'infobox');
    });

    test('《大理寺日志 第三季》首播周四，实际周四+周日', () {
      final r = resolveBroadcastDays(byName(fx['season'], '大理寺日志 第三季'),
          official: official);
      expect(r.weekdays, [4, 7]);
    });

    test('无放送星期时用官方放送表：《列女战纪：女娲石记》→ 周一', () {
      final r = resolveBroadcastDays(byName(fx['season'], '列女战纪：女娲石记'),
          official: official);
      expect(r.weekdays, [1]);
      expect(r.source, 'official');
    });

    test('剧场版 / PV（其他）不进周表', () {
      final movie = (fx['season'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((e) => e['platform'] == '剧场版');
      expect(resolveBroadcastDays(movie, official: official).weekdays, isEmpty);
      final pv = (fx['season'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((e) => e['platform'] == '其他');
      expect(resolveBroadcastDays(pv, official: official).weekdays, isEmpty);
    });
  });

  group('buildSeasonSchedule', () {
    late Map<String, dynamic> fx;
    late Map<int, int> official;
    setUpAll(() {
      fx = jsonDecode(File('test/fixtures/schedule_2026q4.json')
          .readAsStringSync()) as Map<String, dynamic>;
      official = (fx['official'] as Map)
          .map((k, v) => MapEntry(int.parse(k as String), v as int));
    });

    List<Map<String, dynamic>> list(String k) =>
        (fx[k] as List).map((e) => Map<String, dynamic>.from(e)).toList();

    test('每一天里的番都确实在那天更新（与 infobox/官方表一致）', () {
      final b = buildSeasonSchedule(
        seasonRaw: list('season'),
        continuingRaw: list('continuing'),
        official: official,
        today: DateTime(2026, 10, 23),
      );
      final all = [...list('season'), ...list('continuing')];
      for (var d = 1; d <= 7; d++) {
        for (final item in b.days[d - 1]) {
          final raw = all.firstWhere((e) => e['id'] == item.id);
          final expectDays =
              resolveBroadcastDays(raw, official: official).weekdays;
          expect(expectDays, contains(d),
              reason: '${item.nameCn} 不该出现在周$d');
        }
      }
      // 一周多更的条目出现在多天
      int count(String name) => b.days
          .where((day) => day.any((e) => e.nameCn == name))
          .length;
      expect(count('大理寺日志 第三季'), 2);
      expect(count('大夏守墓人'), 2);
      // 剧场版不在表里
      final movieIds = list('season')
          .where((e) => e['platform'] == '剧场版')
          .map((e) => e['id'])
          .toSet();
      expect(movieIds, isNotEmpty);
      expect(b.days.expand((d) => d).where((e) => movieIds.contains(e.id)),
          isEmpty);
    });

    test('跨季长篇：仍在连载的纳入，已完结/估算已播完的排除', () {
      final b = buildSeasonSchedule(
        seasonRaw: const [],
        continuingRaw: list('continuing'),
        official: official,
        today: DateTime(2026, 10, 23),
      );
      final names = {for (final d in b.days) ...d.map((e) => e.nameCn)};
      expect(names, contains('成也萧河')); // 2026-08-03 起 16 集周更，仍在播
      expect(names, isNot(contains('花仙子之魔法香对论'))); // 播放结束 2026-08-15
      expect(names, isNot(contains('城隍录'))); // 播放结束 2026-07-07
      expect(names, isNot(contains('孤雄'))); // 9 集一周三更，早已播完
      expect(b.days[0].any((e) => e.nameCn == '成也萧河'), isTrue); // 周一
      // 首播日期兜底的跨季条目一律不纳入（无可靠更新日）
      expect(b.sources.values, isNot(contains('premiere')));
    });

    test('layout 编解码：多天出现的条目还原后位置不变', () {
      final b = buildSeasonSchedule(
        seasonRaw: list('season'),
        official: official,
        today: DateTime(2026, 10, 23),
      );
      final uniq = <int, BangumiItem>{
        for (final d in b.days)
          for (final e in d) e.id: e,
      };
      final back = decodeScheduleLayout(b.layout, uniq.values)!;
      for (var i = 0; i < 7; i++) {
        expect(back[i].map((e) => e.id).toList(),
            b.days[i].map((e) => e.id).toList());
      }
      expect(decodeScheduleLayout('', uniq.values), isNull);
      expect(decodeScheduleLayout('垃圾', uniq.values), isNull);
    });
  });

  group('首页分类（Bangumi 公共标签）', () {
    test('分类请求走 meta_tags（产地+题材），不再用用户标签 tag', () {
      final p = BangumiApi.buildBangumiListParams(tag: '日常');
      final f = p['filter'] as Map<String, dynamic>;
      expect(f['meta_tags'], ['中国', '日常']);
      expect(f.containsKey('tag'), isFalse);
      expect(p['sort'], 'heat');
    });
    test('「搞笑」映射到公共标签「喜剧」', () {
      final f = BangumiApi.buildBangumiListParams(tag: '搞笑')['filter'] as Map;
      expect(f['meta_tags'], ['中国', '喜剧']);
    });
    test('推荐流保持 v1.8.0 口径（产地用户标签 + 热度）', () {
      final f = BangumiApi.buildBangumiListParams()['filter'] as Map;
      expect(f['tag'], ['中国']);
      expect(f.containsKey('meta_tags'), isFalse);
    });
    test('分类列表不含国漫下几乎为空的日番题材', () {
      final labels = kAnimeCategories.map((c) => c.label).toSet();
      for (final jpOnly in ['后宫', '轻改', '偶像', '异世界', '百合', '机战']) {
        expect(labels, isNot(contains(jpOnly)));
      }
      expect(labels.length, kAnimeCategories.length); // 无重名
      expect(kAnimeCategories.every((c) => c.count >= 29), isTrue);
    });
  });
}
