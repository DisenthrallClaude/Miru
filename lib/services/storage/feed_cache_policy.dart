/// 推荐页 / 时间表缓存的过期策略。
///
/// 纯函数，方便单测。Hive 读写仍在 [FeedCache] 里。
abstract final class FeedCachePolicy {
  /// 推荐页：12 小时后视为过期，启动时先展示旧数据再后台刷新。
  static const Duration popularTtl = Duration(hours: 12);

  /// 时间表：当季缓存 6 小时后后台刷新，避免一周内新番开播看不见。
  static const Duration calendarTtl = Duration(hours: 6);

  static bool isStale({
    required int updatedAtMs,
    required Duration ttl,
    DateTime? now,
  }) {
    if (updatedAtMs <= 0) return true;
    final updated = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
    return (now ?? DateTime.now()).isAfter(updated.add(ttl));
  }
}
