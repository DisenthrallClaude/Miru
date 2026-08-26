import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 从内嵌页面 HTML / 脚本文本中提取真实媒体直链。
///
/// 处理三类形态：
/// 1. 页面 URL 的 query 参数携带完整媒体链接（如 player.php?url=xx.mp4）；
/// 2. 全文中的绝对直链（含 m3u8/mp4/flv/mkv/mov/webm/ts 后缀）；
/// 3. 协议相对地址（//cdn.example.com/x.m3u8），补全 https。
///
/// 注意右侧边界 (?=$|[?#])：路径中间出现同名后缀（如 hls/123.ts/index.m3u8）
/// 时不能提前截断。
String decodeVideoSource(String iframeUrl) {
  // 实测：输入含非法 % 序列（如裸「100%」）时 Uri.decodeFull 会直接抛
  // ArgumentError: Illegal percent encoding，把整条解析链路炸断。
  // 这里容错：decode 失败就按原文继续，提取正则自己会跳过无关文本。
  final decodedUrl = _safeDecodeFull(iframeUrl);

  // 优先：query 参数里携带完整媒体链接（旧版逐参数检查的主路径，必须保留）
  try {
    for (final value in Uri.parse(decodedUrl).queryParameters.values) {
      if (value.isEmpty) continue;
      final extracted = _extractMediaUrl(value);
      if (extracted != null) return Uri.encodeFull(extracted);
    }
  } catch (_) {
    // URL 解析失败则退回全文提取
  }

  final direct = _extractMediaUrl(decodedUrl);
  if (direct != null) return Uri.encodeFull(direct);

  // 兜底：原样返回（由上层决定如何处理）
  return Uri.encodeFull(decodedUrl);
}

/// 容错版 Uri.decodeFull：非法百分号编码不抛异常，返回原文。
String _safeDecodeFull(String input) {
  try {
    return Uri.decodeFull(input);
  } catch (_) {
    return input;
  }
}

/// 在 [input] 中查找第一个媒体直链；找不到返回 null。
String? _extractMediaUrl(String input) {
  const suffix = r'(?:m3u8|mp4|flv|mkv|mov|webm|ts)';
  // 绝对地址：以 http(s) 开头，媒体后缀后必须紧跟结尾、? 或 #
  final absolute = RegExp(
    'https?://[^\\s"\'<>]+?\\.$suffix(?=\$|[?#])',
    caseSensitive: false,
  );
  final match = absolute.firstMatch(input);
  if (match != null) return match.group(0);

  // 协议相对地址：补全 https
  final protocolRelative = RegExp(
    '//[^\\s"\'<>]+?\\.$suffix(?=\$|[?#])',
    caseSensitive: false,
  );
  final relativeMatch = protocolRelative.firstMatch(input);
  if (relativeMatch != null) {
    return 'https:${relativeMatch.group(0)!}';
  }
  return null;
}

int extractEpisodeNumber(String input) {
  final regExp = RegExp(r'第?(\d+)[话集]?');
  final match = regExp.firstMatch(input);

  if (match != null && match.group(1) != null) {
    return int.tryParse(match.group(1)!) ?? 0;
  }

  return 0;
}

Future<String> getPlayerTempPath() async {
  final directory = await getTemporaryDirectory();
  return directory.path;
}

String buildShadersAbsolutePath(String baseDirectory, List<String> shaders) {
  final absolutePaths = shaders.map((shader) {
    return path.join(baseDirectory, shader);
  }).toList();
  if (Platform.isWindows) {
    return absolutePaths.join(';');
  }
  return absolutePaths.join(':');
}
