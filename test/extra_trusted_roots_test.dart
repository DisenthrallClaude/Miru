import 'package:flutter_test/flutter_test.dart';
import 'package:miru/utils/extra_trusted_roots.dart';

void main() {
  test('v2: 追加根包含 SSL.com TLS RSA Root CA 2022 等，且可构建 SecurityContext', () {
    expect(
        RegExp('BEGIN CERTIFICATE').allMatches(ExtraTrustedRoots.pem).length,
        greaterThan(50));
    expect(ExtraTrustedRoots.context, isNotNull);
    final c = ExtraTrustedRoots.newHttpClient();
    c.close(force: true);
  });
}
