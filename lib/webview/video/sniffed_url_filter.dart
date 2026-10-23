/// 嗅探回调侧统一的广告/统计域黑名单。
///
/// 各 WebView 嗅探实现的 JS 侧只零散排除了 googleads 等少数域；
/// 误报的广告 URL 一旦交给 mpv 会打开失败再走一整轮换源重试。
/// 这里与快解（FastVideoSourceResolver._adHostHints）和 legacy 实现
/// 的网络层拦截保持同一份黑名单，Dart 回调侧统一兜底。
abstract final class SniffedUrlFilter {
  static const List<String> _adHostHints = [
    'googleads',
    'googlesyndication',
    'adtrafficquality',
    'doubleclick',
    'prestrain.html',
    'prestrain%2e.html',
  ];

  /// [url] 是否命中广告/统计域黑名单。
  static bool isAdUrl(String url) {
    final lower = url.toLowerCase();
    return _adHostHints.any(lower.contains);
  }
}
