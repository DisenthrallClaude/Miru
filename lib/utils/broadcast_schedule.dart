/// v1.8.1：时间表「哪天更新」的判定（纯函数，可单测）。
///
/// **根因**（v1.8.0 及以前）：时间表把条目的**首播日期**换算成星期几当作
/// 「每周更新日」。国漫（WEB）普遍首播日 ≠ 常规更新日：首播连更多集、
/// 中途改档（「星期三→星期日（20话起）」）、一周多更（「星期四、星期日」）。
/// 实测 2026 秋季：《大夏守墓人》首播周三、实际周三+周四更新；
/// 《大理寺日志 第三季》首播周四、实际周四+周日；另有剧场版、PV、主题曲
/// 这类根本不按周更新的条目混在表里；跨季长篇（年番）首播在上季之前
/// 而完全缺席。
///
/// **修复**：更新日按优先级取
/// 1. 条目维基 infobox「放送星期」（支持多日、「→」改档取最新、「每日」）；
/// 2. Bangumi 官方每日放送表（next.bgm.tv/p1/calendar，1=周一…7=周日）；
/// 3. 兜底才用首播日期的星期。
/// 并剔除剧场版/其他（PV、MV）；当季视图额外纳入「首播早于本季但仍在连载」
/// 的长篇（有放送星期且未完结：播放结束日期 ≥ 今天，或按集数估算未播完）。
///
/// 日期一律按**日历日**解析（`yyyy-MM-dd` / `yyyy年M月d日`），不经过 UTC
/// 换算，星期几与设备时区无关；Bangumi 的放送星期按中国/日本本地时间填写，
/// 与 UTC+8 用户一致。
library;

const _dayChars = {
  '一': 1,
  '二': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '日': 7,
  '天': 7,
  '七': 7,
};

/// 解析 infobox「放送星期」为 1..7（周一..周日），升序去重。
///
/// 例：「星期四」→[4]；「星期四、星期日」→[4,7]；「星期日、一、二」→[1,2,7]；
/// 「星期三→星期日（20话起）」→[7]；「周一至周五」→[1..5]；「每日」→[1..7]；
/// 「不定期」/空 → []。
List<int> parseBroadcastWeekdays(String? raw) {
  if (raw == null) return const [];
  var s = raw.trim();
  if (s.isEmpty) return const [];
  // 改档：取最后一个箭头之后的部分
  for (final arrow in ['→', '->', '⇒', '改为', '改至']) {
    final i = s.lastIndexOf(arrow);
    if (i >= 0) s = s.substring(i + arrow.length);
  }
  // 去掉括号注释
  s = s.replaceAll(RegExp(r'[（(][^）)]*[）)]'), '');
  if (RegExp(r'每日|每天|日更|天天').hasMatch(s)) {
    return const [1, 2, 3, 4, 5, 6, 7];
  }
  final out = <int>{};
  // 区间：周一至周五 / 星期一~星期五 / 一到五
  final range = RegExp(
      r'([一二三四五六日天七])\s*(?:至|到|~|～|-|－|—)\s*(?:星期|周|礼拜)?([一二三四五六日天七])');
  s = s.replaceAllMapped(range, (m) {
    final a = _dayChars[m.group(1)]!;
    final b = _dayChars[m.group(2)]!;
    if (a <= b) {
      for (var d = a; d <= b; d++) {
        out.add(d);
      }
    } else {
      for (var d = a; d <= 7; d++) {
        out.add(d);
      }
      for (var d = 1; d <= b; d++) {
        out.add(d);
      }
    }
    return ' ';
  });
  // 只认「星期/周/礼拜」引导的单字；省略写法（「星期日、一、二」）的分隔符
  // 单字只有在字段里出现过「星期/周/礼拜」时才算，避免「一次性放送」误判周一。
  if (RegExp(r'星期|周|礼拜').hasMatch(s)) {
    final token =
        RegExp(r'(?:星期|周|礼拜|[、，,/／\s和及&])([一二三四五六日天七])');
    for (final m in token.allMatches(s)) {
      out.add(_dayChars[m.group(1)]!);
    }
  }
  final list = out.toList()..sort();
  return list;
}

/// 读 infobox 的某个键（值可能是字符串，也可能是 [{v: ...}] 列表）。
String? infoboxValue(Map<String, dynamic> subject, String key) {
  final box = subject['infobox'];
  if (box is! List) return null;
  for (final e in box) {
    if (e is! Map || e['key'] != key) continue;
    final v = e['value'];
    if (v is String) return v;
    if (v is List) {
      return v
          .map((x) => x is Map ? (x['v'] ?? '').toString() : x.toString())
          .where((x) => x.isNotEmpty)
          .join('、');
    }
  }
  return null;
}

/// 解析日历日：`2026-10-05`、`2026年10月5日`、`2026/10/5`。时间部分忽略。
DateTime? parseCalendarDate(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'(\d{4})\s*[-年/.]\s*(\d{1,2})\s*[-月/.]\s*(\d{1,2})')
      .firstMatch(raw);
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return DateTime(y, mo, d);
}

/// 日历日对应的星期（1..7），解析失败返回 null。
int? weekdayOfDate(String? raw) => parseCalendarDate(raw)?.weekday;

/// 不按周更新的形式（剧场版、PV/MV/主题曲等「其他」）。
bool isNonWeeklyPlatform(Map<String, dynamic> subject) {
  final p = (subject['platform'] ?? '').toString();
  return p == '剧场版' || p == '其他';
}

/// 判定结果。
class BroadcastResolution {
  const BroadcastResolution(this.weekdays, this.source);

  /// 1..7；空表示不进时间表。
  final List<int> weekdays;

  /// infobox / official / premiere / none
  final String source;
}

/// 一个条目应出现在哪些天。
BroadcastResolution resolveBroadcastDays(
  Map<String, dynamic> subject, {
  Map<int, int> official = const {},
}) {
  if (isNonWeeklyPlatform(subject)) {
    return const BroadcastResolution([], 'none');
  }
  final fromInfobox = parseBroadcastWeekdays(infoboxValue(subject, '放送星期'));
  if (fromInfobox.isNotEmpty) {
    return BroadcastResolution(fromInfobox, 'infobox');
  }
  final id = subject['id'];
  if (id is int && official.containsKey(id)) {
    return BroadcastResolution([official[id]!], 'official');
  }
  final w = weekdayOfDate((subject['date'] ?? '').toString());
  if (w != null) return BroadcastResolution([w], 'premiere');
  return const BroadcastResolution([], 'none');
}

/// 首播早于本季的条目此刻是否仍在连载。
///
/// * 有「播放结束」：结束日 ≥ today-7 天（上周刚完结的仍留一周）；
/// * 无结束日：按集数与每周更新次数估算末集日期，+14 天容差 ≥ today；
/// * 集数未知（0）：仅当官方每日放送表里有它才算在播。
bool isStillAiring(
  Map<String, dynamic> subject, {
  required DateTime today,
  required List<int> weekdays,
  Map<int, int> official = const {},
}) {
  final id = subject['id'];
  final end = parseCalendarDate(infoboxValue(subject, '播放结束'));
  if (end != null) {
    return !end.isBefore(today.subtract(const Duration(days: 7)));
  }
  final start = parseCalendarDate((subject['date'] ?? '').toString());
  final eps = (subject['eps'] is int && (subject['eps'] as int) > 0)
      ? subject['eps'] as int
      : (subject['total_episodes'] is int
          ? subject['total_episodes'] as int
          : 0);
  if (start == null || eps <= 0) {
    return id is int && official.containsKey(id);
  }
  final perWeek = weekdays.isEmpty ? 1 : weekdays.length;
  final weeks = (eps / perWeek).ceil();
  final estEnd = start.add(Duration(days: weeks * 7 + 14));
  return !estEnd.isBefore(today);
}
