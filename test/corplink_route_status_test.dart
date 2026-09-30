import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core status carries per-node split routes without conflating full routes', () {
    final status = SgCoreStatus.fromJson({
      'serverName': 'Test-Node',
      'present': true,
      'initialized': true,
      'ready': true,
      'routesPresent': true,
      'routeSplit': ['10.20.0.0/16', '2001:db8:1::/64'],
      'routeFull': ['0.0.0.0/0'],
      'routeInvalid': 1,
    });
    expect(status.routesPresent, isTrue);
    expect(status.routeSplit, ['10.20.0.0/16', '2001:db8:1::/64']);
    expect(status.routeFull, ['0.0.0.0/0']);
    expect(status.routeInvalid, 1);
    expect(status.phase, SgConnectionPhase.ready);
  });

  test('older cores do not invent route metadata', () {
    final status = SgCoreStatus.fromJson({'present': true});
    expect(status.routesPresent, isFalse);
    expect(status.routeSplit, isEmpty);
    expect(status.routeFull, isEmpty);
    expect(status.routeInvalid, 0);
  });
}
