import 'dart:async';

import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an unresponsive native getter is bounded and cannot start late', () async {
    final gate = CorplinkVpnStartGate();
    final nativeRead = Completer<bool>();
    var starts = 0;
    expect(await gate.ensureReady(
      isNativeReady: () => nativeRead.future,
      requestStart: () async { starts++; },
      settle: () async {},
      timeout: const Duration(milliseconds: 30),
    ), isFalse);
    nativeRead.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(starts, 0);
    expect(await gate.ensureReady(
      isNativeReady: () async => true,
      requestStart: () async { starts++; },
      settle: () async {},
    ), isTrue);
    expect(starts, 0);
  });

  test('an unresponsive startup does not hold the shared gate forever', () async {
    final gate = CorplinkVpnStartGate();
    expect(await gate.ensureReady(
      isNativeReady: () async => false,
      requestStart: () => Completer<void>().future,
      settle: () async {},
      timeout: const Duration(milliseconds: 30),
    ), isFalse);
    expect(await gate.ensureReady(
      isNativeReady: () async => true,
      requestStart: () async {},
      settle: () async {},
    ), isTrue);
  });

  test('desktop and Android proxy-only startup never poll for a native TUN', () async {
    final gate = CorplinkVpnStartGate();
    var nativeReads = 0;
    var starts = 0;
    expect(await gate.ensureReady(
      waitForNative: false,
      isNativeReady: () async { nativeReads++; return false; },
      requestStart: () async { starts++; },
      settle: () async {},
    ), isTrue);
    expect(nativeReads, 0);
    expect(starts, 1);
  });

  test('successful native startup does not restart on later checks', () async {
    final gate = CorplinkVpnStartGate();
    var nativeReady = false;
    final events = <String>[];
    Future<void> refresh(String name) async {
      if (await gate.ensureReady(
        isNativeReady: () async => nativeReady,
        requestStart: () async { events.add('start'); nativeReady = true; },
        settle: () async {},
      )) events.add(name);
    }
    await Future.wait([refresh('INTL'), refresh('Office')]);
    expect(events, ['start', 'INTL', 'Office']);
    events.clear();
    await refresh('INTL');
    expect(events, ['INTL']);
  });

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
