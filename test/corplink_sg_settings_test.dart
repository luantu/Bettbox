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

    expect(request['platform'], 'ldap');
    expect(request['password'], 'secret');
  });
}
