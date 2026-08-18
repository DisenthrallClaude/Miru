/// 当前线路解析失败后，按「同一集、下一条线路」的顺序给出候选。
///
/// 播放源规则失效是 Miru 最常见的播放失败原因；同一部番通常有多条
/// 播放线路，自动换一条比让用户空手面对「播放器内部错误」有效得多。
abstract final class PlaybackRoadFallback {
  /// 返回除 [currentRoad] 外、确实有这一集的线路下标，保持原有顺序。
  static List<int> nextRoads({
    required int currentRoad,
    required int roadCount,
    required bool Function(int road) hasEpisode,
  }) {
    if (roadCount <= 0) return const [];
    final result = <int>[];
    for (var i = 0; i < roadCount; i++) {
      if (i == currentRoad) continue;
      if (hasEpisode(i)) result.add(i);
    }
    return result;
  }

  static int? firstAlternate({
    required int currentRoad,
    required int roadCount,
    required bool Function(int road) hasEpisode,
  }) {
    final roads = nextRoads(
      currentRoad: currentRoad,
      roadCount: roadCount,
      hasEpisode: hasEpisode,
    );
    return roads.isEmpty ? null : roads.first;
  }
}
