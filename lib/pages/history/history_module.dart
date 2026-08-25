import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/history/history_page.dart';
import 'package:miru/pages/history/history_controller.dart';

final historyModule = createModule(
  path: '/history',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => HistoryPage(
        controller: inject<HistoryController>(),
      ),
    );
  },
);
