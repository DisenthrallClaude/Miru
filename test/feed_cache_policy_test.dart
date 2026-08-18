import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/storage/feed_cache_policy.dart';

void main() {
  group('FeedCachePolicy', () {
    final now = DateTime(2026, 8, 18, 12);

    test('missing timestamp is always stale', () {
      expect(
        FeedCachePolicy.isStale(
          updatedAtMs: 0,
          ttl: FeedCachePolicy.popularTtl,
          now: now,
        ),
        isTrue,
      );
    });

    test('fresh cache is not stale', () {
      final updated = now.subtract(const Duration(hours: 2));
      expect(
        FeedCachePolicy.isStale(
          updatedAtMs: updated.millisecondsSinceEpoch,
          ttl: FeedCachePolicy.popularTtl,
          now: now,
        ),
        isFalse,
      );
    });

    test('popular cache expires after 12 hours', () {
      final updated = now.subtract(const Duration(hours: 12, minutes: 1));
      expect(
        FeedCachePolicy.isStale(
          updatedAtMs: updated.millisecondsSinceEpoch,
          ttl: FeedCachePolicy.popularTtl,
          now: now,
        ),
        isTrue,
      );
    });

    test('calendar cache expires after 6 hours', () {
      final updated = now.subtract(const Duration(hours: 6, minutes: 1));
      expect(
        FeedCachePolicy.isStale(
          updatedAtMs: updated.millisecondsSinceEpoch,
          ttl: FeedCachePolicy.calendarTtl,
          now: now,
        ),
        isTrue,
      );
    });
  });
}
