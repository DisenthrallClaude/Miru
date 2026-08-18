import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  group('needUpdate', () {
    test('compares dotted versions', () {
      expect(needUpdate('1.0.0', '1.0.1'), isTrue);
      expect(needUpdate('2.2.8', '2.2.8'), isFalse);
      expect(needUpdate('2.2.9', '2.2.8'), isFalse);
    });

    test('strips a leading v so GitHub tags compare correctly', () {
      expect(needUpdate('2.2.8', 'v2.2.9'), isTrue);
      expect(needUpdate('v2.2.8', '2.2.8'), isFalse);
    });

    test('ignores pre-release / build suffixes', () {
      expect(needUpdate('2.2.8', '2.2.9+20209'), isTrue);
      expect(needUpdate('2.2.8+20208', '2.2.8'), isFalse);
    });
  });
}
