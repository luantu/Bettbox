import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android SG upgrades through the secure-storage v10 migration bridge',
      () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains('flutter_secure_storage: ^10.3.3'));
    expect(pubspec, contains('migration bridge before 11'));
  });
}
