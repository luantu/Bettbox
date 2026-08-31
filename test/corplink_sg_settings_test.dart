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
}
