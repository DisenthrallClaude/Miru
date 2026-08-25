import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/core_module.dart';
import 'package:miru/pages/index_module.dart';

final appModule = createModule(
  register: (c) {
    c
      ..module(coreModule)
      ..module(indexModule);
  },
);
