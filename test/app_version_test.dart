import 'package:flutter_test/flutter_test.dart';

import 'package:open_chat/src/app_version_gate.dart';

void main() {
  group('compareVersions', () {
    test('equal versions compare as zero', () {
      expect(compareVersions('1.0.1', '1.0.1'), 0);
    });
    test('higher patch wins', () {
      expect(compareVersions('1.0.2', '1.0.1'), greaterThan(0));
      expect(compareVersions('1.0.1', '1.0.2'), lessThan(0));
    });
    test('minor beats patch regardless of depth', () {
      expect(compareVersions('1.10.0', '1.9.99'), greaterThan(0));
    });
    test('major wins over everything', () {
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    });
    test('missing segments count as zero', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0', '1.0.1'), lessThan(0));
    });
    test('build metadata is ignored', () {
      expect(compareVersions('1.0.1+2', '1.0.1'), 0);
      expect(compareVersions('1.0.1+7', '1.0.1+2'), 0);
    });
    test('garbage segments are treated as zero', () {
      expect(compareVersions('a.b', '0.0'), 0);
    });
  });
}
