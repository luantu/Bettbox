import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/services/corplink_node_delay_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const publicTestUrl = 'https://example.com/generate_204';
  const privateTestUrl = 'https://inside.example.invalid/ready';

  test('dedicated CorpLink WG keeps its HTTPS probe despite global override', () {
    const groups = [
      Group(
        name: 'Fuzhou-Node-1',
        type: GroupType.Selector,
        testUrl: privateTestUrl,
        all: [Proxy(name: 'Fuzhou-Node-1-WG', type: 'WireGuard')],
      ),
    ];
    expect(
      resolveCorplinkDelayUrl(
        proxyName: 'Fuzhou-Node-1-WG',
        preferredUrl: privateTestUrl,
        ordinaryUrl: publicTestUrl,
        groups: groups,
      ),
      privateTestUrl,
    );
  });

  test('unrelated proxy still obeys the global test URL', () {
    const groups = [
      Group(
        name: 'AirportGroup',
        type: GroupType.Selector,
        testUrl: privateTestUrl,
        all: [Proxy(name: 'Airport-WG', type: 'WireGuard')],
      ),
    ];
    expect(
      resolveCorplinkDelayUrl(
        proxyName: 'Airport-WG',
        preferredUrl: privateTestUrl,
        ordinaryUrl: publicTestUrl,
        groups: groups,
      ),
      publicTestUrl,
    );
  });

  test('INTL WG uses its ChatGPT probe instead of the global URL', () {
    const intlUrl = 'https://chatgpt.com/robots.txt';
    const groups = [
      Group(
        name: 'FZ-INT-Node',
        type: GroupType.Selector,
        testUrl: intlUrl,
        all: [Proxy(name: 'FZ-INT-Node-WG', type: 'WireGuard')],
      ),
    ];
    expect(
      resolveCorplinkDelayUrl(
        proxyName: 'FZ-INT-Node-WG',
        preferredUrl: intlUrl,
        ordinaryUrl: publicTestUrl,
        groups: groups,
      ),
      intlUrl,
    );
  });

  test('CorpLink without a configured HTTPS probe keeps ordinary test URL', () {
    const groups = [
      Group(
        name: 'Fuzhou-Node-1',
        type: GroupType.Selector,
        all: [Proxy(name: 'Fuzhou-Node-1-WG', type: 'WireGuard')],
      ),
    ];
    expect(
      resolveCorplinkDelayUrl(
        proxyName: 'Fuzhou-Node-1-WG',
        preferredUrl: '',
        ordinaryUrl: publicTestUrl,
        groups: groups,
      ),
      publicTestUrl,
    );
  });
}
