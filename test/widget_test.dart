// 最小冒烟测试：不依赖插件/Hive/网络，仅验证启动页占位组件可渲染。
// （原文件是空 testWidgets 壳，无任何断言——保留结构但补上真实期望，
//  让 `flutter test` 至少能捕获最基本的渲染回归。）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/pages/init_page.dart';

void main() {
  testWidgets('LoadingWidget renders a Scaffold smoke test',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoadingWidget()));

    expect(find.byType(Scaffold), findsOneWidget);
  });
}
