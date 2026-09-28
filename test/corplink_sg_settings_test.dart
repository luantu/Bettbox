import 'package:bett_box/services/corplink_sg.dart';
import 'package:flutter_test/flutter_test.dart';

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
        cookiePath: '/private/cookies.json');
    mergeCorplinkSgOverlay(config, settings: settings, auth: auth,
        cookiePath: '/private/cookies.json');

    expect((config['proxies'] as List).map((p) => p['name']).toList(),
        ['Airport-A', 'SG-Node']);
    final groups = config['proxy-groups'] as List;
    expect(groups.where((g) => g['name'] == 'SG-OpenAI').length, 1);
    expect((groups.first['proxies'] as List), ['SG-Node', 'Airport-A']);
    expect((config['rules'] as List).where(
        (r) => r == 'DOMAIN-SUFFIX,chatgpt.com,SG-OpenAI').length, 1);
    expect((config['rules'] as List).last, 'MATCH,DIRECT');
  });
}
