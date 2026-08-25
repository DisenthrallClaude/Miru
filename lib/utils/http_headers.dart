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
