import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/video/playback_road_fallback.dart';

void main() {
  group('PlaybackRoadFallback', () {
    test('skips the current road and roads missing this episode', () {
      final next = PlaybackRoadFallback.nextRoads(
        currentRoad: 0,
        roadCount: 4,
        hasEpisode: (road) => road != 2,
      );
      expect(next, [1, 3]);
    });

    test('returns empty when there is no alternate road', () {
      expect(
        PlaybackRoadFallback.nextRoads(
          currentRoad: 0,
          roadCount: 1,
          hasEpisode: (_) => true,
        ),
        isEmpty,
      );
      expect(
        PlaybackRoadFallback.firstAlternate(
          currentRoad: 0,
          roadCount: 2,
          hasEpisode: (_) => false,
        ),
        isNull,
      );
    });

    test('picks the first remaining road in original order', () {
      expect(
        PlaybackRoadFallback.firstAlternate(
          currentRoad: 1,
          roadCount: 3,
          hasEpisode: (_) => true,
        ),
        0,
      );
    });
  });
}
