import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native VPN readiness action has a serializable wire method', () {
    const action = Action(method: ActionMethod.getAndroidVpnReady,
        data: null, id: 'native-ready');
    expect(action.toJson(), {
      'method': 'getAndroidVpnReady', 'data': null, 'id': 'native-ready',
    });
    expect(Action.fromJson({
      'method': 'getAndroidVpnReady', 'data': null, 'id': 'native-ready',
    }).method, ActionMethod.getAndroidVpnReady);
    expect(ActionResult.fromJson({
      'method': 'getAndroidVpnReady', 'data': false, 'id': 'native-ready',
    }).data, isFalse);
  });
}
