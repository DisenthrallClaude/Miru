import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/navigation.dart';
import 'package:miru/pages/collect/collect_page.dart';
import 'package:miru/pages/collect/collect_controller.dart';

final collectModule = createModule(
  path: '/collect',
  register: (c) {
    c.route(
      '/',
      // B3：切 tab 的过场必须在叶子路由上声明才会生效
      //（flutter_modular 只取被推送路由的转场配置）。
      transition: tabTransition,
      child: (context, state) => CollectPage(
        controller: inject<CollectController>(),
      ),
    );
  },
);
