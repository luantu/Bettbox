import 'dart:async';

import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent nodes wait for native TUN readiness with one VPN start', () async {
    final gate = CorplinkVpnStartGate();
    final nativeStarted = Completer<void>();
    var ready = false;
    var starts = 0;
    final handshakes = <String>[];
    Future<void> refresh(String name) async {
      final accepted = await gate.ensureReady(
        isNativeReady: () async => ready,
        requestStart: () async { starts++; },
        settle: () => nativeStarted.future,
      );
      if (accepted) handshakes.add(name);
    }
    final intl = refresh('INTL');
    final office = refresh('Office');
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    expect(handshakes, isEmpty);
    ready = true;
    nativeStarted.complete();
    await Future.wait([intl, office]);
    expect(handshakes, ['INTL', 'Office']);
  });

  test('already established native TUN does not restart the VPN', () async {
    final gate = CorplinkVpnStartGate();
    var starts = 0;
    var waits = 0;
    final accepted = await gate.ensureReady(
      isNativeReady: () async => true,
      requestStart: () async { starts++; },
      settle: () async { waits++; },
    );
    expect(accepted, isTrue);
    expect(starts, 0);
    expect(waits, 0);
  });

  test('native startup timeout does not release a tunnel handshake and can retry', () async {
    final gate = CorplinkVpnStartGate();
    var ready = false;
    var starts = 0;
    var waits = 0;
    final accepted = await gate.ensureReady(
      isNativeReady: () async => ready,
      requestStart: () async { starts++; },
      settle: () async { waits++; },
      maxChecks: 3,
    );
    expect(accepted, isFalse);
    expect(starts, 1);
    expect(waits, 2);
    ready = true;
    expect(await gate.ensureReady(
      isNativeReady: () async => ready,
      requestStart: () async { starts++; },
      settle: () async {},
    ), isTrue);
    expect(starts, 1);
  });

  test('failed VPN start clears the shared gate for a subsequent attempt', () async {
    final gate = CorplinkVpnStartGate();
    var ready = false;
    final failed = gate.ensureReady(
      isNativeReady: () async => ready,
      requestStart: () async => throw StateError('startup failed'),
      settle: () async {},
    );
    await expectLater(failed, throwsStateError);
    expect(await gate.ensureReady(
      isNativeReady: () async => ready,
      requestStart: () async { ready = true; },
      settle: () async {},
    ), isTrue);
  });
}
