import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/utils/broadcast_schedule.dart';

/// v1.8.1：把搜索得到的原始条目编排成「周一…周日」7 天时间表。
///
/// [seasonRaw]：按首播日期落在本季窗口内的条目；
/// [continuingRaw]：首播早于本季窗口的条目（仅当季视图传入），只保留仍在
/// 连载的（见 [isStillAiring]）；
/// [official]：官方每日放送表 id→星期。
///
/// 一个条目可以出现在多天（一周多更）；[BangumiItem.airWeekday] 写入其
/// 第一个更新日，方便旧缓存逻辑兜底。返回的 [ScheduleBuild.layout] 记录
/// 每天的 id 顺序，供本地缓存原样还原。
class ScheduleBuild {
  ScheduleBuild(this.days, this.sources);

  final List<List<BangumiItem>> days;

  /// id → 判定来源（infobox/official/premiere），用于日志与单测。
  final Map<int, String> sources;

  String get layout => encodeScheduleLayout(days);
}

ScheduleBuild buildSeasonSchedule({
  required List<Map<String, dynamic>> seasonRaw,
  List<Map<String, dynamic>> continuingRaw = const [],
  Map<int, int> official = const {},
  DateTime? today,
}) {
  final now = today ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final days = List.generate(7, (_) => <BangumiItem>[]);
  final sources = <int, String>{};
  final seen = <int>{};

  void place(Map<String, dynamic> raw, {required bool continuing}) {
    final id = raw['id'];
    if (id is! int || !seen.add(id)) return;
    final r = resolveBroadcastDays(raw, official: official);
    if (r.weekdays.isEmpty) return;
    if (continuing) {
      // 跨季长篇必须有可靠的更新日（infobox/官方表），且仍在连载。
      if (r.source == 'premiere') return;
      if (!isStillAiring(raw,
          today: day, weekdays: r.weekdays, official: official)) {
        return;
      }
    }
    final BangumiItem item;
    try {
      item = BangumiItem.fromJson(raw);
    } catch (_) {
      return;
    }
    item.airWeekday = r.weekdays.first;
    sources[id] = r.source;
    for (final w in r.weekdays) {
      days[w - 1].add(item);
    }
  }

  for (final raw in seasonRaw) {
    place(raw, continuing: false);
  }
  for (final raw in continuingRaw) {
    place(raw, continuing: true);
  }
  return ScheduleBuild(days, sources);
}

/// 「1:12,34;2:;3:56…」——每天的条目 id 顺序。
String encodeScheduleLayout(List<List<BangumiItem>> days) {
  final parts = <String>[];
  for (var i = 0; i < days.length; i++) {
    parts.add('${i + 1}:${days[i].map((e) => e.id).join(',')}');
  }
  return parts.join(';');
}

/// 按 layout 还原 7 天分组；layout 无效时返回 null（调用方回落按 airWeekday 分组）。
List<List<BangumiItem>>? decodeScheduleLayout(
    String layout, Iterable<BangumiItem> items) {
  if (layout.isEmpty) return null;
  final byId = {for (final it in items) it.id: it};
  final days = List.generate(7, (_) => <BangumiItem>[]);
  try {
    for (final part in layout.split(';')) {
      final kv = part.split(':');
      if (kv.length != 2) return null;
      final d = int.parse(kv[0]);
      if (d < 1 || d > 7) return null;
      if (kv[1].isEmpty) continue;
      for (final s in kv[1].split(',')) {
        final it = byId[int.parse(s)];
        if (it != null) days[d - 1].add(it);
      }
    }
  } catch (_) {
    return null;
  }
  return days;
}
