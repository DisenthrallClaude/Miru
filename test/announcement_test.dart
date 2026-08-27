import 'package:flutter_test/flutter_test.dart';
import 'package:miru/modules/announcement/announcement.dart';
import 'package:miru/services/announcement/announcement_service.dart';

Announcement _item({
  String id = 'a1',
  bool enabled = true,
  int priority = 0,
  String title = '标题',
  String minAppVersion = '',
  String maxAppVersion = '',
  String startAt = '',
  String endAt = '',
  String frequency = 'once',
}) {
  final raw = <String, dynamic>{
    'id': id,
    'enabled': enabled,
    'priority': priority,
    'title': title,
    'minAppVersion': minAppVersion,
    'maxAppVersion': maxAppVersion,
    'showFrequency': frequency,
  };
  if (startAt.isNotEmpty) raw['startAt'] = startAt;
  if (endAt.isNotEmpty) raw['endAt'] = endAt;
  final parsed = Announcement.fromJson(raw);
  assert(parsed != null, 'fixture must parse');
  return parsed!;
}

void main() {
  group('AnnouncementFeed.parse', () {
    test('完整结构解析所有字段', () {
      const raw = '''
      {
        "announcements": [
          {
            "id": "welcome",
            "enabled": false,
            "priority": 7,
            "title": "欢迎",
            "body": "第一行\\n第二行",
            "coverImage": "https://example.com/a.jpg",
            "actions": [
              {"label": "打开", "type": "url", "value": "https://example.com"}
            ],
            "minAppVersion": "1.3.0",
            "maxAppVersion": "2.0.0",
            "startAt": "2026-09-01T00:00:00+08:00",
            "endAt": "2026-09-30T23:59:59+08:00",
            "showFrequency": "daily"
          }
        ]
      }
      ''';
      final feed = AnnouncementFeed.parse(raw)!;
      expect(feed.announcements, hasLength(1));
      final item = feed.announcements.single;
      expect(item.id, 'welcome');
      expect(item.enabled, isFalse);
      expect(item.priority, 7);
      expect(item.body, contains('\n'));
      expect(item.actions.single.label, '打开');
      expect(item.actions.single.isUrl, isTrue);
      expect(item.startAt, isNotNull);
      expect(item.endAt, isNotNull);
      expect(item.frequency, AnnouncementFrequency.daily);
    });

    test('单条损坏只跳过该条，不影响其余', () {
      const raw = '''
      {
        "announcements": [
          {"id": "", "title": "没有 id，作废"},
          "not-a-map",
          {"id": "ok", "title": "正常"}
        ]
      }
      ''';
      final feed = AnnouncementFeed.parse(raw)!;
      expect(feed.announcements, hasLength(1));
      expect(feed.announcements.single.id, 'ok');
    });

    test('整体损坏返回 null（非 JSON / 缺 announcements）', () {
      expect(AnnouncementFeed.parse('not json {'), isNull);
      expect(AnnouncementFeed.parse('{"foo": 1}'), isNull);
      expect(AnnouncementFeed.parse('{"announcements": "x"}'), isNull);
    });

    test('action 缺 label 或 value 时被丢弃', () {
      const raw = '''
      {
        "announcements": [
          {
            "id": "a",
            "title": "t",
            "actions": [
              {"label": "", "value": "x"},
              {"label": "ok", "value": "y"},
              {"label": "no-value"}
            ]
          }
        ]
      }
      ''';
      final feed = AnnouncementFeed.parse(raw)!;
      expect(feed.announcements.single.actions, hasLength(1));
      expect(feed.announcements.single.actions.single.label, 'ok');
    });
  });

  group('AnnouncementFeed 删除语义（对接规格）', () {
    test('deletedIds 墓碑解析：结构完整取 id，损坏条目跳过', () {
      const raw = '''
      {
        "announcements": [
          {"id": "live1", "title": "存活"}
        ],
        "deletedIds": [
          {"id": "gone1", "deletedAt": "2026-08-27T00:00:00+08:00"},
          {"id": "gone2", "deletedAt": "2026-08-26T00:00:00+08:00"},
          {"deletedAt": "缺 id 的损坏条目"},
          "不是对象的条目"
        ]
      }
      ''';
      final feed = AnnouncementFeed.parse(raw)!;
      expect(feed.deletedIds, containsAll(['gone1', 'gone2']));
      expect(feed.deletedIds, hasLength(2));
      expect(feed.liveIds, {'live1'});
    });

    test('liveIds 含 enabled=false 的条目（下线≠删除）', () {
      const raw = '''
      {
        "announcements": [
          {"id": "a", "title": "x", "enabled": false},
          {"id": "b", "title": "y"}
        ]
      }
      ''';
      final feed = AnnouncementFeed.parse(raw)!;
      expect(feed.liveIds, containsAll(['a', 'b']));
    });

    test('缺 deletedIds 字段 → 空墓碑列表', () {
      const raw = '{"announcements": [{"id": "a", "title": "x"}]}';
      final feed = AnnouncementFeed.parse(raw)!;
      expect(feed.deletedIds, isEmpty);
    });
  });

  group('Announcement 字段默认值', () {
    test('minAppVersion 缺失/空串 → 默认 1.3.0（规格约定）', () {
      final missing = Announcement.fromJson({'id': 'a', 'title': 'x'})!;
      expect(missing.minAppVersion, '1.3.0');

      final empty = Announcement.fromJson(
          {'id': 'a', 'title': 'x', 'minAppVersion': ''})!;
      expect(empty.minAppVersion, '1.3.0');

      final explicit = Announcement.fromJson(
          {'id': 'a', 'title': 'x', 'minAppVersion': '1.4.0'})!;
      expect(explicit.minAppVersion, '1.4.0');
    });

    test('font 缺失 → 空串；未知 font → 默认字体不报错', () {
      final missing = Announcement.fromJson({'id': 'a', 'title': 'x'})!;
      expect(missing.font, '');
      expect(missing.resolvedFont.fontFamily, isNull);

      final unknown =
          Announcement.fromJson({'id': 'a', 'title': 'x', 'font': '不存在的字体'})!;
      expect(unknown.resolvedFont.fontFamily, isNull);
      expect(unknown.resolvedFont.fallback, isNull);
    });
  });

  group('AnnouncementFont 映射', () {
    test('衬线类 → serif + 内置 Noto Serif SC 兜底', () {
      for (final name in ['serif', 'xiaoWei', 'playfair', 'garamond']) {
        final font = AnnouncementFont.fromName(name);
        expect(font.fontFamily, 'serif', reason: name);
        expect(font.fallback, contains('Noto_Serif_SC'), reason: name);
      }
    });

    test('楷体/手写类 → cursive + 兜底', () {
      for (final name in ['kai', 'longCang', 'zhiMang', 'liuJian', 'maShan']) {
        final font = AnnouncementFont.fromName(name);
        expect(font.fontFamily, 'cursive', reason: name);
        expect(font.fallback, isNotNull, reason: name);
      }
    });

    test('mono → 等宽；黑体/显示类与空值 → 默认', () {
      expect(AnnouncementFont.fromName('mono').fontFamily, 'monospace');
      for (final name in ['', 'sans', 'notoSans', 'huangYou', 'kuaiLe', null]) {
        expect(AnnouncementFont.fromName(name).fontFamily, isNull,
            reason: '$name');
      }
    });
  });

  group('AnnouncementService.selectAnnouncement', () {
    final now = DateTime.parse('2026-09-10T12:00:00+08:00');

    test('enabled=false 的公告不展示', () {
      final feed = AnnouncementFeed(announcements: [
        _item(id: 'off', enabled: false, priority: 99),
      ]);
      final picked = AnnouncementService.selectAnnouncement(
        feed: feed, appVersion: '1.3.0', now: now, dismissed: const {});
      expect(picked, isNull);
    });

    test('版本区间过滤：低于 min 不弹，高于 max 不弹，区间内弹出', () {
      AnnouncementFeed feed( String min, String max) => AnnouncementFeed(
          announcements: [_item(id: 'x', minAppVersion: min, maxAppVersion: max)]);

      Announcement? pick(String appVersion) =>
          AnnouncementService.selectAnnouncement(
            feed: feed('1.3.0', '2.0.0'),
            appVersion: appVersion,
            now: now,
            dismissed: const {},
          );

      expect(pick('1.2.0'), isNull, reason: '低于 minAppVersion');
      expect(pick('1.3.0'), isNotNull, reason: '恰好等于下界');
      expect(pick('1.7.5'), isNotNull, reason: '区间内');
      expect(pick('2.0.0'), isNotNull, reason: '恰好等于上界');
      expect(pick('2.0.1'), isNull, reason: '高于 maxAppVersion');
    });

    test('时间窗过滤：未开始/已过期不弹，进行中弹出', () {
      Announcement? pick(String startAt, String endAt) {
        final feed = AnnouncementFeed(
            announcements: [_item(id: 't', startAt: startAt, endAt: endAt)]);
        return AnnouncementService.selectAnnouncement(
          feed: feed, appVersion: '1.3.0', now: now, dismissed: const {});
      }

      expect(pick('2026-09-11T00:00:00+08:00', ''), isNull, reason: '尚未开始');
      expect(pick('', '2026-09-09T00:00:00+08:00'), isNull, reason: '已过期');
      expect(pick('2026-09-01T00:00:00+08:00', '2026-09-30T00:00:00+08:00'),
          isNotNull,
          reason: '进行中');
      expect(pick('', ''), isNotNull, reason: '不限制时间');
    });

    test('频控：once 关闭过即不再弹；daily 同一天不弹、隔天可弹；everyLaunch 总是弹', () {
      final dayKey = '2026-09-10';

      Announcement? pick(String frequency, Map<String, String> dismissed) {
        final feed = AnnouncementFeed(
            announcements: [_item(id: 'f', frequency: frequency)]);
        return AnnouncementService.selectAnnouncement(
          feed: feed, appVersion: '1.3.0', now: now, dismissed: dismissed);
      }

      expect(pick('once', {'f': dayKey}), isNull);
      expect(pick('once', {'f': '2025-01-01'}), isNull,
          reason: 'once 不看日期，关闭过就不再弹');
      expect(pick('daily', {'f': dayKey}), isNull, reason: '同一天已看过');
      expect(pick('daily', {'f': '2026-09-09'}), isNotNull, reason: '隔天可再弹');
      expect(pick('everyLaunch', {'f': dayKey}), isNotNull);
    });

    test('多条命中取 priority 最高的一条；平级取先出现的', () {
      final feed = AnnouncementFeed(announcements: [
        _item(id: 'low', priority: 1),
        _item(id: 'high', priority: 10),
        _item(id: 'high2', priority: 10),
      ]);
      final picked = AnnouncementService.selectAnnouncement(
        feed: feed, appVersion: '1.3.0', now: now, dismissed: const {});
      expect(picked!.id, 'high');
    });
  });
}
