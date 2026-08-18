import 'dart:math';

bool needUpdate(String localVersion, String remoteVersion) {
  final localVersionList = _versionSegments(localVersion);
  final remoteVersionList = _versionSegments(remoteVersion);
  final maxLength = max(localVersionList.length, remoteVersionList.length);
  for (var i = 0; i < maxLength; i++) {
    final localSegment = i < localVersionList.length ? localVersionList[i] : 0;
    final remoteSegment =
        i < remoteVersionList.length ? remoteVersionList[i] : 0;
    if (remoteSegment > localSegment) {
      return true;
    } else if (remoteSegment < localSegment) {
      return false;
    }
  }
  return false;
}

/// GitHub 的 `tag_name` 经常是 `v2.2.9`，pubspec 则是 `2.2.8+20208`。
/// 比较前先剥掉前缀和构建号，避免 `int.parse('v2')` 直接炸掉检查更新。
List<int> _versionSegments(String version) {
  var cleaned = version.trim();
  if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
    cleaned = cleaned.substring(1);
  }
  final core = cleaned.split(RegExp(r'[-+]')).first;
  return [
    for (final part in core.split('.')) int.tryParse(part) ?? 0,
  ];
}
