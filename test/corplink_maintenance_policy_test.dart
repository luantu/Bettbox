import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smart capture pause allows protected SG maintenance', () {
    expect(allowsCorplinkMaintenance(userWanted: true, running: false,
      smartPaused: true, compatibilityPaused: false, transportReady: true), isTrue);
    expect(allowsCorplinkMaintenance(userWanted: true, running: true,
      smartPaused: false, compatibilityPaused: false, transportReady: true), isTrue);
  });
  test('user stop, compatibility pause and missing protection forbid maintenance', () {
    for (final item in [
      (false, true, false, false, true),
      (true, true, false, true, true),
      (true, false, true, false, false),
      (true, false, false, false, true),
    ]) {
      expect(allowsCorplinkMaintenance(userWanted: item.$1, running: item.$2,
        smartPaused: item.$3, compatibilityPaused: item.$4, transportReady: item.$5), isFalse);
    }
  });
}
