import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/bangumi/bangumi_setting.dart';

final bangumiModule = createModule(
  path: '/bangumi',
  register: (c) {
    c.route('/', child: (context, state) => const BangumiEditorPage());
  },
);
