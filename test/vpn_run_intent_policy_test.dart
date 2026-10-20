import 'package:bett_box/services/vpn_run_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VPN startup run intent', () {
    test('first launch follows auto-run setting', () {
      expect(
        shouldStartVpnAtStartup(
          hasProfile: true,
          alreadyRunning: false,
          autoRun: true,
          lastRunIntent: null,
        ),
        isTrue,
      );
      expect(
        shouldStartVpnAtStartup(
          hasProfile: true,
          alreadyRunning: false,
          autoRun: false,
          lastRunIntent: null,
        ),
        isFalse,
      );
    });

    test('explicit manual stop overrides auto-run', () {
      expect(
        shouldStartVpnAtStartup(
          hasProfile: true,
          alreadyRunning: false,
          autoRun: true,
          lastRunIntent: false,
        ),
        isFalse,
      );
      expect(allowsAutomaticVpnRestart(false), isFalse);
    });

    test('explicit start permits recovery while auto-run remains enabled', () {
      expect(
        shouldStartVpnAtStartup(
          hasProfile: true,
          alreadyRunning: false,
          autoRun: true,
          lastRunIntent: true,
        ),
        isTrue,
      );
      expect(allowsAutomaticVpnRestart(true), isTrue);
    });

    test('automatic service start uses explicit intent then auto-run fallback', () {
      expect(
        shouldStartAutomaticVpnService(
          autoRun: true,
          lastRunIntent: false,
        ),
        isFalse,
      );
      expect(
        shouldStartAutomaticVpnService(
          autoRun: false,
          lastRunIntent: true,
        ),
        isTrue,
      );
      expect(
        shouldStartAutomaticVpnService(
          autoRun: false,
          lastRunIntent: null,
        ),
        isFalse,
      );
      expect(
        shouldStartAutomaticVpnService(
          autoRun: true,
          lastRunIntent: null,
        ),
        isTrue,
      );
    });

    test('auto-run off and missing profile never start', () {
      expect(
        shouldStartVpnAtStartup(
          hasProfile: true,
          alreadyRunning: false,
          autoRun: false,
          lastRunIntent: true,
        ),
        isFalse,
      );
      expect(
        shouldStartVpnAtStartup(
          hasProfile: false,
          alreadyRunning: true,
          autoRun: true,
          lastRunIntent: true,
        ),
        isFalse,
      );
    });

    test('an already running service remains attached', () {
      expect(
        shouldStartVpnAtStartup(
          hasProfile: true,
          alreadyRunning: true,
          autoRun: false,
          lastRunIntent: false,
        ),
        isTrue,
      );
    });

    test('legacy runtime state is never promoted to explicit user intent', () {
      expect(
        resolveVpnUserRunIntent(
          explicitIntent: null,
        ),
        isNull,
      );
      expect(
        resolveVpnUserRunIntent(
          explicitIntent: true,
        ),
        isTrue,
      );
    });
  });
}
