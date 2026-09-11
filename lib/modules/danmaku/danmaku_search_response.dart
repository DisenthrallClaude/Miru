/// `/api/v2/search/episodes` 的响应模型。
///
/// 该端点的条目不带封面、评分与开播日期（与 `/api/v2/search/anime`
/// 不同），只保留手动弹幕检索弹窗消费的字段。
/// （同步自上游 Kazumi c32db78。）
class DanmakuSearchAnime {
  final int animeId;
  final String animeTitle;
  final String typeDescription;

  const DanmakuSearchAnime({
    required this.animeId,
    required this.animeTitle,
    required this.typeDescription,
  });

  factory DanmakuSearchAnime.fromJson(Map<String, dynamic> json) {
    return DanmakuSearchAnime(
      animeId: json['animeId'],
      animeTitle: json['animeTitle'],
      typeDescription: json['typeDescription'] ?? '',
    );
  }
}

class DanmakuSearchResponse {
  final List<DanmakuSearchAnime> animes;

  /// 结果集被截断；用户应收窄关键词。
  final bool hasMore;

  const DanmakuSearchResponse({
    required this.animes,
    required this.hasMore,
  });

  factory DanmakuSearchResponse.fromJson(Map<String, dynamic> json) {
    var list = json['animes'] as List;
    return DanmakuSearchResponse(
      animes: list.map((i) => DanmakuSearchAnime.fromJson(i)).toList(),
      hasMore: json['hasMore'] ?? false,
    );
  }
}
