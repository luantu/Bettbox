import 'package:bett_box/models/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android VPN options preserve route exclusions across JSON', () {
    final options = AndroidVpnOptions.fromJson({
      'enable': true,
      'port': 7890,
      'accessControl': null,
      'allowBypass': false,
      'systemProxy': false,
      'bypassDomain': <String>[],
      'ipv4Address': '198.51.100.1/30',
      'ipv6Address': '',
      'routeAddress': <String>[],
      'routeExcludeAddress': ['192.168.110.0/24'],
      'routeMode': 'config',
      'dnsServerAddress': '198.51.100.2',
      'dozeSuspend': false,
      'mtu': 9000,
    });

    expect(options.routeExcludeAddress, ['192.168.110.0/24']);
    expect(options.toJson()['routeExcludeAddress'], ['192.168.110.0/24']);
  });
}
