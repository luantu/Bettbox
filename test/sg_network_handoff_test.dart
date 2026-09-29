import 'package:bett_box/services/sg_network_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('coalesces rapid physical network changes before reconnecting',
      (tester) async {
    var reconnects = 0;
    final recovery = SgNetworkHandoffRecovery(
      settleDelay: const Duration(seconds: 5),
      reconnect: () async { reconnects++; },
    );

    recovery.networkChanged();
    await tester.pump(const Duration(seconds: 3));
    recovery.networkChanged();
    await tester.pump(const Duration(seconds: 4));
    expect(reconnects, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(reconnects, 1);
    recovery.dispose();
  });

  testWidgets('disposed network recovery never reconnects', (tester) async {
    var reconnects = 0;
    final recovery = SgNetworkHandoffRecovery(
      settleDelay: const Duration(seconds: 5),
      reconnect: () async { reconnects++; },
    );
    recovery.networkChanged();
    recovery.dispose();
    await tester.pump(const Duration(seconds: 6));
    expect(reconnects, 0);
  });
}
