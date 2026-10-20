import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('temporarily bypasses TUN for login and waits for native resume', () async {
    final events = <String>[];
    var readinessChecks = 0;
    final gate = CorplinkAuthorizationNetworkGate();

    final result = await gate.run<bool>(
      beginBypass: () async {
        events.add('begin');
        return 7;
      },
      action: () async {
        events.add('login');
        return true;
      },
      endBypass: (token) async {
        expect(token, 7);
        events.add('end');
        return true;
      },
      isNativeReady: () async {
        readinessChecks++;
        events.add('ready-$readinessChecks');
        return readinessChecks == 2;
      },
      settle: () async => events.add('settle'),
    );

    expect(result, isTrue);
    expect(events, ['begin', 'login', 'end', 'ready-1', 'settle', 'ready-2']);
  });

  test('does not touch VPN lifecycle when no bypass is needed', () async {
    final events = <String>[];
    final gate = CorplinkAuthorizationNetworkGate();

    final result = await gate.run<String>(
      beginBypass: () async => null,
      action: () async {
        events.add('login');
        return 'ok';
      },
      endBypass: (_) async {
        events.add('end');
        return true;
      },
      isNativeReady: () async {
        events.add('ready');
        return true;
      },
      settle: () async => events.add('settle'),
    );

    expect(result, 'ok');
    expect(events, ['login']);
  });

  test('restores VPN in finally when login throws', () async {
    final events = <String>[];
    final gate = CorplinkAuthorizationNetworkGate();

    await expectLater(
      gate.run<void>(
        beginBypass: () async => 9,
        action: () async {
          events.add('login');
          throw StateError('login failed');
        },
        endBypass: (_) async {
          events.add('end');
          return true;
        },
        isNativeReady: () async {
          events.add('ready');
          return true;
        },
        settle: () async => events.add('settle'),
      ),
      throwsStateError,
    );
    expect(events, ['login', 'end', 'ready']);
  });

  test('does not resume after user stop or smart pause cancels the token', () async {
    final events = <String>[];
    final gate = CorplinkAuthorizationNetworkGate();

    final result = await gate.run<bool>(
      beginBypass: () async => 11,
      action: () async => true,
      endBypass: (_) async {
        events.add('end');
        return false;
      },
      isNativeReady: () async {
        events.add('ready');
        return true;
      },
      settle: () async => events.add('settle'),
    );

    expect(result, isTrue);
    expect(events, ['end']);
  });
}
