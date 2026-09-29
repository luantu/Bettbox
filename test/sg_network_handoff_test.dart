import 'dart:async';

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
    recovery.cancel();
  });

  testWidgets('canceled network recovery never reconnects', (tester) async {
    var reconnects = 0;
    final recovery = SgNetworkHandoffRecovery(
      settleDelay: const Duration(seconds: 5),
      reconnect: () async { reconnects++; },
    );
    recovery.networkChanged();
    recovery.cancel();
    await tester.pump(const Duration(seconds: 6));
    expect(reconnects, 0);
  });

  testWidgets('new handoff waits for an in-flight reconnect', (tester) async {
    final first = Completer<void>();
    var reconnects = 0;
    final recovery = SgNetworkHandoffRecovery(
      settleDelay: const Duration(seconds: 1),
      reconnect: () {
        reconnects++;
        return reconnects == 1 ? first.future : Future<void>.value();
      },
    );
    recovery.networkChanged();
    await tester.pump(const Duration(seconds: 1));
    expect(reconnects, 1);
    recovery.networkChanged();
    await tester.pump(const Duration(seconds: 1));
    expect(reconnects, 1);
    first.complete();
    await tester.pump();
    expect(reconnects, 2);
    recovery.cancel();
  });

  testWidgets('cancel drops a queued handoff during an active reconnect',
      (tester) async {
    final first = Completer<void>();
    var reconnects = 0;
    final recovery = SgNetworkHandoffRecovery(
      settleDelay: const Duration(seconds: 1),
      reconnect: () {
        reconnects++;
        return first.future;
      },
    );
    recovery.networkChanged();
    await tester.pump(const Duration(seconds: 1));
    recovery.networkChanged();
    recovery.cancel();
    first.complete();
    await tester.pump(const Duration(seconds: 2));
    expect(reconnects, 1);
  });
}
