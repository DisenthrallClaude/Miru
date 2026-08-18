import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/feed_cache_policy.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 推荐页与时间表的本地持久化缓存。
///
/// 目的：首次加载后把结果落盘，之后启动直接读本地、完全不联网，
/// 避免每次进 App 都重新拉取（尤其推荐页的置顶清单是几十个请求）。
///
/// 失效策略：
/// * 推荐页 —— 先读缓存秒开，超过 [FeedCachePolicy.popularTtl] 后后台静默刷新；
/// * 时间表 —— 以「季度」为键，换季必重取；同季度超过
///   [FeedCachePolicy.calendarTtl] 后后台静默刷新。
///
/// `BangumiItem` 本身是 HiveType，可直接存入 Box，无需序列化。
abstract final class FeedCache {
  /// 推荐页最多缓存多少条，避免无限下拉后缓存膨胀。
  static const int maxPopularItems = 240;

  // --------------------------------------------------------------------- 推荐页

  static bool get hasPopular => GStorage.popularCache.isNotEmpty;

  static List<BangumiItem> loadPopular() =>
      GStorage.popularCache.values.toList(growable: false);

  /// 已翻页到的 offset，与缓存内容一起恢复。
  static int get popularOffset =>
      GStorage.getSetting(SettingsKeys.popularCacheOffset);

  static bool get isPopularStale => FeedCachePolicy.isStale(
        updatedAtMs: GStorage.getSetting(SettingsKeys.popularCacheUpdatedAt),
        ttl: FeedCachePolicy.popularTtl,
      );

  static Future<void> savePopular(
    List<BangumiItem> items, {
    required int offset,
  }) async {
    // 空结果不写缓存，否则一次网络失败会把用户永久锁在空白页
    if (items.isEmpty) return;
    try {
      final box = GStorage.popularCache;
      await box.clear();
      await box.addAll(
        items.length > maxPopularItems
            ? items.sublist(0, maxPopularItems)
            : items,
      );
      await box.flush();
      await GStorage.putSetting(SettingsKeys.popularCacheOffset, offset);
      await GStorage.putSetting(
        SettingsKeys.popularCacheUpdatedAt,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      KazumiLogger().w('FeedCache: save popular failed', error: e);
    }
  }

  // -------------------------------------------------------------------- 时间表

  static String get cachedCalendarSeason =>
      GStorage.getSetting(SettingsKeys.calendarCacheSeason);

  static bool hasCalendarFor(String season) =>
      season.isNotEmpty &&
      season == cachedCalendarSeason &&
      GStorage.calendarCache.isNotEmpty;

  static bool get isCalendarStale => FeedCachePolicy.isStale(
        updatedAtMs: GStorage.getSetting(SettingsKeys.calendarCacheUpdatedAt),
        ttl: FeedCachePolicy.calendarTtl,
      );

  /// 按 airWeekday 还原成 7 天分组。
  /// 与 `BangumiApi.getCalendarBySearch` 的分组方式一致，
  /// 且各天内部顺序与写入时相同（写入时按天依次展平）。
  static List<List<BangumiItem>> loadCalendar() {
    final grouped = List.generate(7, (_) => <BangumiItem>[]);
    for (final item in GStorage.calendarCache.values) {
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
    final flat = calendar.expand((day) => day).toList();
    if (flat.isEmpty) return;
    try {
      final box = GStorage.calendarCache;
      await box.clear();
      await box.addAll(flat);
      await box.flush();
      await GStorage.putSetting(SettingsKeys.calendarCacheSeason, season);
      await GStorage.putSetting(
        SettingsKeys.calendarCacheUpdatedAt,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      KazumiLogger().w('FeedCache: save calendar failed', error: e);
    }
  }

  // ---------------------------------------------------------------------- 清理

  /// 供「清除缓存」一类的入口调用。
  static Future<void> clear() async {
    try {
      await GStorage.popularCache.clear();
      await GStorage.calendarCache.clear();
      await GStorage.putSetting(SettingsKeys.calendarCacheSeason, '');
      await GStorage.putSetting(SettingsKeys.popularCacheOffset, 0);
    } catch (e) {
      KazumiLogger().w('FeedCache: clear failed', error: e);
    }
  }
}
