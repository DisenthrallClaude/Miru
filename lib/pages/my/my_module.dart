import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/navigation.dart';
import 'package:miru/pages/my/my_controller.dart';
import 'package:miru/pages/my/my_page.dart';

final myModule = createModule(
  path: '/my',
  register: (c) {
    c.route(
      '/',
      // B3：切 tab 的过场必须在叶子路由上声明才会生效
      //（flutter_modular 只取被推送路由的转场配置）。
      transition: tabTransition,
      child: (context, state) => MyPage(
        controller: inject<MyController>(),
      ),
    );
  },
);
