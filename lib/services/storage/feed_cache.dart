import 'package:miru/request/apis/season_schedule.dart';
import 'package:miru/modules/bangumi/bangumi_item.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';

/// 推荐页与时间表的本地持久化缓存。
///
/// 目的：首次加载后把结果落盘，之后启动直接读本地、完全不联网，
/// 避免每次进 App 都重新拉取（尤其推荐页的置顶清单是几十个请求）。
///
/// 失效策略：
/// * 推荐页 —— 不自动失效，只有用户主动刷新时才重新联网；
/// * 时间表 —— 以「季度」为键，季度没变就一直用缓存，换季自动重取。
///
/// `BangumiItem` 本身是 HiveType，可直接存入 Box，无需序列化。
abstract final class FeedCache {
  /// 推荐页最多缓存多少条，避免无限下拉后缓存膨胀。
  static const int maxPopularItems = 240;

  // --------------------------------------------------------------------- 推荐页

  /// 冷启动懒加载守卫：缓存盒尚未就绪时按「无缓存」处理，
  /// 推荐页自然回退联网（见 GStorage.ensureFeedCachesOpen）。
  static bool get hasPopular =>
      GStorage.popularCacheOrNull?.isNotEmpty ?? false;

  static List<BangumiItem> loadPopular() =>
      GStorage.popularCacheOrNull?.values.toList(growable: false) ??
      const <BangumiItem>[];

  /// 已翻页到的 offset，与缓存内容一起恢复。
  static int get popularOffset =>
      GStorage.getSetting(SettingsKeys.popularCacheOffset);

  static Future<void> savePopular(
    List<BangumiItem> items, {
    required int offset,
  }) async {
    // 空结果不写缓存，否则一次网络失败会把用户永久锁在空白页
    if (items.isEmpty) return;
    try {
      await GStorage.ensureFeedCachesOpen();
      final box = GStorage.popularCache;
      await box.clear();
      await box.addAll(
        items.length > maxPopularItems
            ? items.sublist(0, maxPopularItems)
            : items,
      );
      await box.flush();
      await GStorage.putSetting(SettingsKeys.popularCacheOffset, offset);
    } catch (e) {
      MiruLogger().w('FeedCache: save popular failed', error: e);
    }
  }

  // -------------------------------------------------------------------- 时间表

  static String get cachedCalendarSeason =>
      GStorage.getSetting(SettingsKeys.calendarCacheSeason);

  static bool hasCalendarFor(String season) =>
      season.isNotEmpty &&
      season == cachedCalendarSeason &&
      (GStorage.calendarCacheOrNull?.isNotEmpty ?? false);

  /// 缓存是否为 v1.8.1 新格式（带每日 id 顺序）。旧格式按首播星期分组，
  /// 可能错位，调用方应展示后立刻后台刷新。
  static bool get calendarHasLayout =>
      GStorage.getSetting(SettingsKeys.calendarCacheLayout).isNotEmpty;

  /// 缓存写入时间；0 表示未知（旧版缓存）。
  static DateTime? get calendarSavedAt {
    final ms = GStorage.getSetting(SettingsKeys.calendarCacheSavedAt);
    return ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 还原 7 天分组：优先按 v1.8.1 的 layout（支持一部番多天），
  /// 没有 layout 的旧缓存按 airWeekday 分组。
  static List<List<BangumiItem>> loadCalendar() {
    final box = GStorage.calendarCacheOrNull;
    final grouped = List.generate(7, (_) => <BangumiItem>[]);
    if (box == null) return grouped;
    final layout = GStorage.getSetting(SettingsKeys.calendarCacheLayout);
    final byLayout = decodeScheduleLayout(layout, box.values);
    if (byLayout != null && byLayout.any((d) => d.isNotEmpty)) {
      return byLayout;
    }
    for (final item in box.values) {
      final weekday = item.airWeekday;
      if (weekday >= 1 && weekday <= 7) {
        grouped[weekday - 1].add(item);
      }
    }
    return grouped;
  }

  static Future<void> saveCalendar(
    List<List<BangumiItem>> calendar,
    String season,
  ) async {
    // 一部番可在多天出现：落盘去重（Hive 不能重复存同一实例），
    // 每日顺序另存 layout。
    final seen = <int>{};
    final flat = <BangumiItem>[
      for (final day in calendar)
        for (final item in day)
          if (seen.add(item.id)) item,
    ];
    if (flat.isEmpty) return;
    try {
      await GStorage.ensureFeedCachesOpen();
      final box = GStorage.calendarCache;
      await box.clear();
      await box.addAll(flat.map(_copyOf));
      await box.flush();
      await GStorage.putSetting(SettingsKeys.calendarCacheSeason, season);
      await GStorage.putSetting(
          SettingsKeys.calendarCacheLayout, encodeScheduleLayout(calendar));
      await GStorage.putSetting(SettingsKeys.calendarCacheSavedAt,
          DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      MiruLogger().w('FeedCache: save calendar failed', error: e);
    }
  }

  /// 存副本：内存里正在展示的实例不绑定到 Hive 盒（避免同一实例
  /// 跨盒/重复入盒异常，也避免 box.clear 后实例失效）。
  static BangumiItem _copyOf(BangumiItem b) => BangumiItem(
        id: b.id,
        type: b.type,
        name: b.name,
        nameCn: b.nameCn,
        summary: b.summary,
        airDate: b.airDate,
        airWeekday: b.airWeekday,
        rank: b.rank,
        images: Map<String, String>.from(b.images),
        tags: List.of(b.tags),
        alias: List.of(b.alias),
        ratingScore: b.ratingScore,
        votes: b.votes,
        votesCount: List.of(b.votesCount),
        info: b.info,
      );

  // ---------------------------------------------------------------------- 清理

  /// 供「清除缓存」一类的入口调用。
  static Future<void> clear() async {
    try {
      await GStorage.ensureFeedCachesOpen();
      await GStorage.popularCache.clear();
      await GStorage.calendarCache.clear();
      await GStorage.putSetting(SettingsKeys.calendarCacheSeason, '');
      await GStorage.putSetting(SettingsKeys.calendarCacheLayout, '');
      await GStorage.putSetting(SettingsKeys.popularCacheOffset, 0);
    } catch (e) {
      MiruLogger().w('FeedCache: clear failed', error: e);
    }
  }
}
