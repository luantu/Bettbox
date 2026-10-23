import 'package:bett_box/common/smart_network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const home = SmartNetworkRule(
    id: 'home', name: 'Home', ssid: 'Home Wi-Fi', networks: '192.168.110.0/24',
  );
  SmartNetworkSnapshot wifi(String? ssid, {String ip = '192.168.110.23',
    String ssidStatus = 'available', bool selected = true}) =>
      SmartNetworkSnapshot(id: 'wifi', selected: selected, transport: 'wifi',
        ssid: ssid, ssidStatus: ssidStatus,
        ips: [ip], gateways: const ['192.168.110.1']);
  SmartNetworkDecision evaluate(List<SmartNetworkSnapshot> networks, {
    List<SmartNetworkRule> rules = const [home], String legacy = '',
  }) => SmartNetworkPolicy.evaluate(networks: networks,
    rulesJson: SmartNetworkRule.encode(rules), legacyNetworks: legacy);

  test('same subnet at another SSID must not stop VPN', () {
    expect(evaluate([wifi('Hotel')]).match, SmartNetworkMatch.noMatch);
    expect(evaluate([wifi('Home Wi-Fi')]).match, SmartNetworkMatch.match);
  });
  test('SSID and addresses are AND, rules are OR', () {
    expect(evaluate([wifi('Home Wi-Fi', ip: '10.1.1.2')]).match,
      SmartNetworkMatch.noMatch);
    expect(evaluate([wifi('Office')], rules: [home,
      const SmartNetworkRule(id: 'office', name: 'Office', ssid: 'Office'),
    ]).match, SmartNetworkMatch.match);
  });
  test('addresses and SSID cannot be stitched across interfaces', () {
    expect(evaluate([
      wifi('Home Wi-Fi', ip: '10.1.1.2'),
      const SmartNetworkSnapshot(id: 'cell', selected: false,
        transport: 'cellular', ips: ['192.168.110.23']),
    ]).match, SmartNetworkMatch.noMatch);
    expect(evaluate([wifi('Home Wi-Fi', selected: false),
      const SmartNetworkSnapshot(id: 'cell', selected: true,
        transport: 'cellular', ips: ['10.1.1.2']),
    ]).match, SmartNetworkMatch.noMatch);
  });
  test('unknown SSID never falls back to IP-only match', () {
    for (final status in ['permissionRequired', 'locationDisabled', 'unavailable']) {
      expect(evaluate([wifi(null, ssidStatus: status)]).match,
        SmartNetworkMatch.unknown);
    }
    expect(evaluate([wifi('<unknown ssid>')]).match, SmartNetworkMatch.unknown);
  });
  test('known disqualifying address does not wait on SSID', () {
    expect(evaluate([wifi(null, ip: '10.1.1.2', ssidStatus: 'unavailable')]).match,
      SmartNetworkMatch.noMatch);
  });
  test('leaving Wi-Fi for cellular unmatches, total disconnect is unknown', () {
    expect(evaluate([const SmartNetworkSnapshot(id: 'cell', selected: true,
      transport: 'cellular', ips: ['10.1.1.2'])]).match,
      SmartNetworkMatch.noMatch);
    expect(evaluate([]).match, SmartNetworkMatch.unknown);
  });
  test('SSID-only supports Chinese, commas and significant spaces exactly', () {
    const rule = SmartNetworkRule(id: 'cn', name: '中文', ssid: ' 家里,WiFi ');
    expect(evaluate([wifi(' 家里,WiFi ')], rules: [rule]).match,
      SmartNetworkMatch.match);
    expect(evaluate([wifi('家里,WiFi')], rules: [rule]).match,
      SmartNetworkMatch.noMatch);
    expect(evaluate([wifi('home wi-fi')]).match, SmartNetworkMatch.noMatch);
  });
  test('IP-only and gateway rules preserve existing matcher semantics', () {
    const rule = SmartNetworkRule(id: 'gw', name: 'Router',
      networks: 'gateway:192.168.110.1');
    expect(evaluate([wifi('Any')], rules: [rule]).match, SmartNetworkMatch.match);
    expect(evaluate([wifi('Hotel')], rules: [], legacy: '192.168.110.0/24').match,
      SmartNetworkMatch.match);
    expect(evaluate([wifi('Hotel', selected: false)], rules: [],
      legacy: '192.168.110.0/24').match, SmartNetworkMatch.match);
  });
  test('disabled rules and deletion of final rule release smart stop', () {
    expect(evaluate([], rules: []).match, SmartNetworkMatch.noMatch);
    expect(evaluate([], rules: [const SmartNetworkRule(id: 'off', name: 'off',
      enabled: false, ssid: 'Home Wi-Fi')]).match, SmartNetworkMatch.noMatch);
  });
  test('invalid rules cannot accidentally stop VPN', () {
    expect(const SmartNetworkRule(id: 'empty', name: 'Empty').validationError,
      isNotNull);
    expect(const SmartNetworkRule(id: 'bad', name: 'Bad', networks: '1192.168.1.1')
      .validationError, isNotNull);
    for (final json in ['{broken', '{}', '[{"id":"x"}]']) {
      expect(SmartNetworkPolicy.evaluate(networks: [wifi('Home Wi-Fi')],
        rulesJson: json).match, SmartNetworkMatch.unknown);
    }
  });
  test('rules codec preserves names, disabled state and exact SSID', () {
    const rule = SmartNetworkRule(id: 'cn', name: '家里', enabled: false,
      ssid: ' Wi-Fi,中文 ', networks: '192.168.110.0/24');
    final decoded = SmartNetworkRule.decode(SmartNetworkRule.encode([rule])).single;
    expect(decoded.id, 'cn'); expect(decoded.name, '家里');
    expect(decoded.enabled, isFalse); expect(decoded.ssid, ' Wi-Fi,中文 ');
    expect(decoded.networks, '192.168.110.0/24');
    expect(SmartNetworkRule.decode(''), isEmpty);
  });
  test('snapshot decoding never mistakes VPN interface for physical path', () {
    final snapshots = SmartNetworkSnapshot.decode({'networks': [
      {'id': 'tun', 'selected': true, 'transport': 'vpn', 'ips': ['192.168.110.2']},
      {'id': 'wifi', 'selected': true, 'transport': 'wifi', 'ssid': 'Home Wi-Fi',
        'ssidStatus': 'available', 'ips': ['192.168.110.23'], 'gateways': []},
    ]});
    expect(snapshots.length, 1);
    expect(evaluate(snapshots).match, SmartNetworkMatch.match);
  });
  test('manual stop and compatibility pause always override automatic action', () {
    final matched = evaluate([wifi('Home Wi-Fi')]);
    final unmatched = evaluate([wifi('Hotel')]);
    expect(matched.action(isSmartStopped: false, isRunning: true,
      userRunIntent: true), SmartNetworkAction.stop);
    expect(unmatched.action(isSmartStopped: true, isRunning: false,
      userRunIntent: true), SmartNetworkAction.resume);
    expect(unmatched.action(isSmartStopped: true, isRunning: false,
      userRunIntent: false), SmartNetworkAction.clearStopped);
    expect(matched.action(isSmartStopped: false, isRunning: false,
      userRunIntent: false), SmartNetworkAction.none);
    expect(unmatched.action(isSmartStopped: true, isRunning: false,
      userRunIntent: true, compatibilityPaused: true), SmartNetworkAction.none);
    expect(evaluate([]).action(isSmartStopped: true, isRunning: false,
      userRunIntent: true), SmartNetworkAction.none);
  });
}
