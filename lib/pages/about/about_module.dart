import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/about/about_page.dart';
import 'package:miru/pages/logs/logs_page.dart';
import 'package:miru/pages/my/my_controller.dart';
import 'package:miru/request/config/api_endpoints.dart';

final aboutModule = createModule(
  path: '/about',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => AboutPage(
          controller: inject<MyController>(),
        ),
      )
      ..route('/logs', child: (context, state) => const LogsPage())
      ..route(
        '/license',
        child: (context, state) => const LicensePage(
          applicationName: 'Miru',
          applicationVersion: ApiEndpoints.version,
          applicationLegalese: '开源许可证',
        ),
      );
  },
);
