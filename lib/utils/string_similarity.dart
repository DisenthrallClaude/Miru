// 计算两个字符串的编辑距离。
//
// 注意（F25）：此工具并非死代码——danmaku_api.getBangumiIDByTitle
// 仍以它作标题相似度兜底（bgmBangumiID 反查失败/无 ID 时的路径）；
// 曾有注释声称「已不再使用」与实际调用矛盾，此处修正。
// 调用方注意 O(n·m) 复杂度，仅适用于短标题比较。

import 'dart:math';

int levenshteinDistance(String s1, String s2) {
  if (s1 == s2) return 0;
  if (s1.isEmpty) return s2.length;
  if (s2.isEmpty) return s1.length;

  List<int> v0 = List<int>.generate(s2.length + 1, (i) => i);
  List<int> v1 = List<int>.filled(s2.length + 1, 0);

  for (int i = 0; i < s1.length; i++) {
    v1[0] = i + 1;

    for (int j = 0; j < s2.length; j++) {
      int cost = (s1[i] == s2[j]) ? 0 : 1;
      v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
    }

    for (int j = 0; j < v0.length; j++) {
      v0[j] = v1[j];
    }
  }

  return v1[s2.length];
}

// 计算相似度百分比
double calculateSimilarity(String s1, String s2) {
  int maxLength = max(s1.length, s2.length);
  if (maxLength == 0) return 1.0;
  if (s1 == s2) return 1.0;
  return (1.0 - levenshteinDistance(s1, s2) / maxLength);
}
