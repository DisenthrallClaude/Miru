import 'dart:math';

/// 语义化版本比较（容忍 `v` 前缀、`-beta`/`-rc` 后缀、非数字段）。
///
/// 返回 `true` 表示 `remoteVersion` 比 `localVersion` 新。
/// 无法解析的段按 0 处理；整体无法比较时返回 `false` 并记日志，
/// 避免把「无法比较」误判为「有更新」。
bool needUpdate(String localVersion, String remoteVersion) {
  final localSegments = _parseVersion(localVersion);
  final remoteSegments = _parseVersion(remoteVersion);
  if (localSegments == null || remoteSegments == null) {
    return false;
  }
  final maxLength = max(localSegments.length, remoteSegments.length);
  for (var i = 0; i < maxLength; i++) {
    final localSegment = i < localSegments.length ? localSegments[i] : 0;
    final remoteSegment = i < remoteSegments.length ? remoteSegments[i] : 0;
    if (remoteSegment > localSegment) {
      return true;
    } else if (remoteSegment < localSegment) {
      return false;
    }
  }
  return false;
}

/// 从版本字符串中提取数值段。
///
/// 支持 `2.2.8`、`v2.2.8`、`2.2.8+20208`、`1.7.5-beta.1` 等格式：
/// 取第一个以数字开头的连续数字段，忽略 `v` 前缀与 `+`/`-` 后缀。
List<int>? _parseVersion(String version) {
  if (version.isEmpty) {
    return null;
  }
  final match = RegExp(r'v?(\d+(?:\.\d+)*)').firstMatch(version);
  if (match == null) {
    return null;
  }
  final numericPart = match.group(1)!;
  final segments = <int>[];
  for (final part in numericPart.split('.')) {
    final value = int.tryParse(part);
    if (value == null) {
      return null;
    }
    segments.add(value);
  }
  return segments;
}
