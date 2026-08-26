import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/settings/github/github_settings_page.dart';

final githubModule = createModule(
  path: '/github',
  register: (c) {
    c.route('/', child: (context, state) => const GithubSettingsPage());
  },
);
