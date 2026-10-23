/// 广告/统计 URL 统一判定（v2）。
///
/// 快解层、WebView 嗅探层、云端结果共用同一份规则——任何一层把
/// 广告片（如 AGE 解析器页里的 `/Play/adposter.mp4`）当正片交给 mpv，
/// 用户看到的就是「播了几秒广告就结束」或「加载失败」。
abstract final class AdUrlFilter {
  /// 统计/广告网络域（子串匹配）。
  static const List<String> _hostHints = [
    'googleads',
    'googlesyndication',
    'adtrafficquality',
    'doubleclick',
    'prestrain.html',
    'prestrain%2e.html',
    'hm.baidu.com',
    'cnzz.com',
  ];

  /// 文件名/路径中的广告片特征（大小写不敏感）。
  static final RegExp _mediaAdRe = RegExp(
    r'(adposter|ad_poster|ad-poster|advert|guanggao|preroll|pre_roll|'
    r'/ads?/|/adv/|[/_-]ad\d*\.(mp4|m3u8|flv|ts)(?=$|[?#]))',
    caseSensitive: false,
  );

  /// [url] 是否是广告/统计资源（不应作为正片候选）。
  static bool isAd(String url) {
    final lower = url.toLowerCase();
    if (_hostHints.any(lower.contains)) return true;
    // 只看 path（避免 query 里的随机串误伤）。
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? lower;
    return _mediaAdRe.hasMatch(path);
  }
}
