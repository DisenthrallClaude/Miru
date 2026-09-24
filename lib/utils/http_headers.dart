import 'dart:math';

import 'package:miru/utils/constants.dart';

final _random = Random();

String getRandomUA() {
  return userAgentsList[_random.nextInt(userAgentsList.length)];
}

/// 会话级 User-Agent。
///
/// 同一次运行内的关键出站请求（WebView 解析、mpv 播放、规则站点抓取）
/// 共用同一个 UA。防盗链 CDN 常校验「取链请求与媒体请求的 UA 一致」，
/// 若每次都随机，会出现解析成功但播放 403 的经典故障。
String? _sessionUserAgent;

String getSessionUA() {
  return _sessionUserAgent ??= getRandomUA();
}

String getRandomAcceptedLanguage() {
  return acceptLanguageList[_random.nextInt(acceptLanguageList.length)];
}

/// v1.7.0（P0-6）：播放头合并规则（纯函数，hybrid 与 video_controller
/// 共用）。
///
/// - `referer` 以解析层（嗅探/云端/快解确认的 CDN 真实 referer）为准；
/// - `cookie` 以插件侧（PluginCookieManager 的实时值）为准——用户重新
///   过了 Cloudflare 验证后新的 cf_clearance 在插件头里，绝不能被
///   缓存/嗅探带回的旧 cookie 覆盖（403 → 换源循环的根因）；
/// - 两边都有 cookie 时按 name 合并：插件侧覆盖同名项，解析层独有的
///   项保留（同一 CDN 上不同用途的 cookie 共存）；
/// - 其余键与既有 spread 语义一致（解析层覆盖插件）。
Map<String, String> mergePlaybackHeaders(
  Map<String, String> plugin,
  Map<String, String> resolved,
) {
  final merged = <String, String>{...plugin, ...resolved};
  final pluginCookie = plugin['cookie'];
  final resolvedCookie = resolved['cookie'];
  if (pluginCookie != null &&
      pluginCookie.isNotEmpty &&
      resolvedCookie != null &&
      resolvedCookie.isNotEmpty) {
    merged['cookie'] = mergeCookieHeader(pluginCookie, resolvedCookie);
  }
  return merged;
}

/// 按 name 合并两段 `cookie` 单头：[high] 覆盖 [low] 的同名项，
/// [low] 独有的项保留。
///
/// 例：high=`cf_clearance=new`，low=`cf_clearance=old; a=1`
/// → `cf_clearance=new; a=1`。
String mergeCookieHeader(String high, String low) {
  final merged = <String, String>{};
  void absorb(String raw) {
    for (final pair in raw.split(';')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      if (name.isEmpty) continue;
      // 值里的 '=' 原样保留（base64 padding 等）。
      merged[name] = pair.substring(eq + 1).trim();
    }
  }

  absorb(low);
  absorb(high);
  return merged.entries.map((e) => '${e.key}=${e.value}').join('; ');
}
