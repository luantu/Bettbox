import 'dart:async';

import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_bootstrap.dart';
import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synchronized/synchronized.dart';

void main() {
  test('detects CorpLink settings changes that require profile rebuild', () {
    const before = CorplinkSgSettings(
      enabled: false,
      username: 'user',
      password: '',
      server: 'https://example.invalid',
    );
    const after = CorplinkSgSettings(
      enabled: true,
      username: 'user',
      password: 'secret',
      server: 'https://example.invalid',
    );

    expect(corplinkSgSettingsChanged(before, after), isTrue);
  });

  test('detects OpenAI routing preference changes', () {
    const base = CorplinkSgSettings(
      enabled: true,
      routeOpenAi: true,
      username: 'user',
      password: 'secret',
      server: 'https://example.invalid',
    );
    expect(
      corplinkSgSettingsChanged(
        base,
        const CorplinkSgSettings(
          enabled: true,
          routeOpenAi: false,
          username: 'user',
          password: 'secret',
          server: 'https://example.invalid',
        ),
      ),
      isTrue,
    );
    expect(base.isConfigured, isTrue);
    expect(
      const CorplinkSgSettings(enabled: true).validationError,
      isNotNull,
    );
  });

  test('uses the password machine flow for Android CorpLink login', () {
    final request = buildAndroidCorplinkMachineRequest(
      server: 'https://example.invalid',
      username: 'user',
      password: 'secret',
      deviceName: 'device',
      deviceId: 'id',
      publicKey: 'public',
      privateKey: 'private',
      authFile: '/data/user/0/app/files/config.json',
      cookieFile: '/data/user/0/app/files/corplink_cookies.json',
    );

    expect(request['platform'], 'feilian');
    expect(request['password'], 'secret');
  });

  test('does not reuse authorization from another account or server', () {
    const settings = CorplinkSgSettings(
      enabled: true,
      username: 'new-user',
      password: 'secret',
      server: 'https://new.example.invalid',
    );
    final prior = <String, dynamic>{
      'username': 'old-user',
      'server': 'https://old.example.invalid',
      'private_key': 'private',
      'public_key': 'public',
    };

    expect(corplinkAuthMatchesSettings(prior, settings), isFalse);
    prior['username'] = 'new-user';
    expect(corplinkAuthMatchesSettings(prior, settings), isFalse);
    prior['server'] = 'https://new.example.invalid';
    expect(corplinkAuthMatchesSettings(prior, settings), isTrue);
  });

  test('creates a fail-closed SG group before authorization', () {
    final config = <String, dynamic>{
      'proxies': <dynamic>[],
      'proxy-groups': <dynamic>[],
      'rules': <dynamic>['MATCH,DIRECT'],
    };

    mergeCorplinkSgOverlay(
      config,
      settings: const CorplinkSgSettings(
        enabled: true,
        username: 'user',
        password: 'secret',
        server: 'https://example.invalid',
      ),
    );

    expect(config['proxies'], isEmpty);
    expect((config['proxy-groups'] as List).single['name'], 'SG-OpenAI');
    expect((config['proxy-groups'] as List).single['proxies'], ['REJECT']);
    expect((config['rules'] as List).first, 'DOMAIN-SUFFIX,chatgpt.com,SG-OpenAI');
  });

  test('selects a physical control address, never VPN fake IP', () {
    expect(
      selectCorplinkPhysicalIP(['198.18.0.5', '2001:db8::1', '203.0.113.8']),
      '203.0.113.8',
    );
    expect(selectCorplinkPhysicalIP(['198.19.1.4']), isNull);
    expect(selectCorplinkPhysicalIP(['2001:db8::1']), '2001:db8::1');
  });

  test('stale SG group selection is replaced without changing valid choices', () {
    const members = ['SG-Node', 'Airport-A'];
    expect(shouldReplaceStaleCorplinkSelection('REJECT', members), isTrue);
    expect(shouldReplaceStaleCorplinkSelection('SG-Node', members), isFalse);
    expect(shouldReplaceStaleCorplinkSelection('Airport-A', members), isFalse);
    expect(shouldReplaceStaleCorplinkSelection(null, members), isFalse);
  });

  test('merges authorized SG node once and preserves subscription routing', () {
    final config = <String, dynamic>{
      'proxies': <dynamic>[
        <String, dynamic>{'name': 'Airport-A', 'type': 'socks5'},
      ],
      'proxy-groups': <dynamic>[
        <String, dynamic>{
          'name': 'OpenAI',
          'type': 'select',
          'proxies': <dynamic>['Airport-A'],
        },
      ],
      'rules': <dynamic>['DOMAIN-SUFFIX,example.com,OpenAI', 'MATCH,DIRECT'],
    };
    const settings = CorplinkSgSettings(
      enabled: true,
      username: 'user',
      password: 'secret',
      server: 'https://example.invalid',
    );
    final auth = <String, dynamic>{
      'username': 'user',
      'server': 'https://example.invalid',
      'private_key': 'private',
      'public_key': 'public',
      'device_id': 'device-id',
      'device_name': 'device-name',
      'code': 'otp-seed',
    };

    mergeCorplinkSgOverlay(config, settings: settings, auth: auth,
        cookiePath: '/private/cookies.json', controlIP: '203.0.113.8');
    mergeCorplinkSgOverlay(config, settings: settings, auth: auth,
        cookiePath: '/private/cookies.json', controlIP: '203.0.113.8');

    expect((config['proxies'] as List).map((p) => p['name']).toList(),
        ['Airport-A', 'SG-Node']);
    expect((config['proxies'] as List).last['corplink']['corplink-control-ip'],
        '203.0.113.8');
    final groups = config['proxy-groups'] as List;
    expect(groups.where((g) => g['name'] == 'SG-OpenAI').length, 1);
    expect((groups.first['proxies'] as List), ['SG-Node', 'Airport-A']);
    expect((config['rules'] as List).where(
        (r) => r == 'DOMAIN-SUFFIX,chatgpt.com,SG-OpenAI').length, 1);
    expect((config['rules'] as List).last, 'MATCH,DIRECT');
  });

  test('withholds a failed SG node while keeping the airport profile usable', () {
    final config = <String, dynamic>{
      'proxies': <dynamic>[
        <String, dynamic>{'name': 'Airport-A', 'type': 'socks5'},
      ],
      'proxy-groups': <dynamic>[
        <String, dynamic>{
          'name': 'OpenAI',
          'type': 'select',
          'proxies': <dynamic>['Airport-A'],
        },
      ],
      'rules': <dynamic>['MATCH,OpenAI'],
    };
    const settings = CorplinkSgSettings(
      enabled: true,
      username: 'user',
      password: 'secret',
      server: 'https://example.invalid',
    );
    final auth = <String, dynamic>{
      'username': 'user',
      'server': 'https://example.invalid',
      'private_key': 'private',
      'public_key': 'public',
    };
    mergeCorplinkSgOverlay(config, settings: settings, auth: auth,
        cookiePath: '/private/cookies.json');
    mergeCorplinkSgOverlay(config, settings: settings, auth: auth,
        cookiePath: '/private/cookies.json', suppressNode: true);

    expect((config['proxies'] as List).map((p) => p['name']).toList(),
        ['Airport-A']);
    expect((config['proxy-groups'] as List).first['proxies'], ['Airport-A']);
    expect((config['proxy-groups'] as List).last['proxies'], ['REJECT']);
  });

  test('promotes a downloaded profile over the SG bootstrap profile', () {
    expect(selectProfileAfterImport(sgBootstrapProfileId, 'subscription-1'),
        'subscription-1');
    expect(selectProfileAfterImport('user-selected', 'subscription-2'),
        'user-selected');
    expect(selectProfileAfterImport(null, 'subscription-3'),
        'subscription-3');
  });

  test('recovers only after repeated failures and backs off', () {
    final policy = SgRecoveryPolicy();
    final start = DateTime.utc(2026, 9, 28);
    expect(policy.recordProbe(false, start), SgRecoveryAction.none);
    expect(policy.recordProbe(false, start), SgRecoveryAction.none);
    expect(policy.recordProbe(false, start), SgRecoveryAction.reconnect);
    expect(policy.recordProbe(false, start), SgRecoveryAction.none);
    final afterCooldown = start.add(const Duration(seconds: 31));
    expect(policy.recordProbe(false, afterCooldown),
        SgRecoveryAction.rebuild);
    expect(policy.recordProbe(true, afterCooldown), SgRecoveryAction.none);
    expect(policy.recordProbe(false, afterCooldown), SgRecoveryAction.none);
  });

  test('SG status favors actual handshake over website delay', () {
    final ready = SgCoreStatus.fromJson({
      'present': true,
      'initialized': true,
      'ready': true,
      'rebuildRequired': false,
      'tunnelIp': '10.0.0.2/32',
      'endpoint': 'vpn.example:34080',
    });
    expect(ready.phase, SgConnectionPhase.ready);
    expect(ready.recovery, SgStatusRecovery.none);

    final stale = SgCoreStatus.fromJson({
      'present': true,
      'initialized': true,
      'ready': true,
      'rebuildRequired': true,
    });
    expect(stale.phase, SgConnectionPhase.needsRebuild);
    expect(stale.recovery, SgStatusRecovery.rebuild);
    expect(SgCoreStatus.fromJson({}).recovery, SgStatusRecovery.rebuild);
  });

  test('deferred authorization does not inherit a completed lock zone', () async {
    final scheduler = SgDeferredScheduler();
    final lifecycle = Lock(reentrant: true);
    final completed = Completer<void>();

    await lifecycle.synchronized(() async {
      scheduler.schedule(() async {
        try {
          await lifecycle.synchronized(() async {});
          completed.complete();
        } catch (error, stack) {
          completed.completeError(error, stack);
        }
      });
    });

    await completed.future.timeout(const Duration(seconds: 2));
  });

  test('periodic health checks run outside the startup lock zone', () async {
    final scheduler = SgDeferredScheduler();
    final lifecycle = Lock(reentrant: true);
    final completed = Completer<void>();
    late Timer timer;

    await lifecycle.synchronized(() async {
      timer = scheduler.run(() => Timer.periodic(
        const Duration(milliseconds: 10),
        (current) async {
          current.cancel();
          try {
            await lifecycle.synchronized(() async {});
            completed.complete();
          } catch (error, stack) {
            completed.completeError(error, stack);
          }
        },
      ));
    });
    try {
      await completed.future.timeout(const Duration(seconds: 2));
    } finally {
      timer.cancel();
    }
  });
}
