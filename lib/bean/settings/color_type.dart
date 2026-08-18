import 'package:flutter/material.dart';
import 'package:kazumi/utils/theme.dart';

final List<Map<String, dynamic>> colorThemeTypes = [
  // index 0 是「默认」，必须与 kDefaultSeedColor 保持一致，
  // 否则色板高亮态会与实际生效的主题色不符。
  {'color': kDefaultSeedColor, 'label': '默认'},
  {'color': Colors.teal, 'label': '青色'},
  {'color': Colors.blue, 'label': '蓝色'},
  {'color': Colors.indigo, 'label': '靛蓝色'},
  {'color': const Color(0xff6750a4), 'label': '紫罗兰色'},
  {'color': Colors.pink, 'label': '粉红色'},
  {'color': Colors.yellow, 'label': '黄色'},
  {'color': Colors.orange, 'label': '橙色'},
  {'color': Colors.deepOrange, 'label': '深橙色'},
];
