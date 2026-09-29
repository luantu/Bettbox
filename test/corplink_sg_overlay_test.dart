import 'dart:convert';

import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/services/corplink_sg_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const settings = CorplinkSgSettings(
    enabled: true,
    username: 'user',
    password: 'password',
    server: 'https://example.invalid',
  );
  const selections = [
    CorplinkNodeSelection(serverName: 'FZ-INT-Node'),
    CorplinkNodeSelection(serverName: 'FUZHOU-NODE-1'),
  ];
  const keyPairs = {
    'FZ-INT-Node': CorplinkNodeKeyPair(publicKey: 'intl-public', privateKey: 'intl-private'),
    'FUZHOU-NODE-1': CorplinkNodeKeyPair(publicKey: 'fuzhou-public', privateKey: 'fuzhou-private'),
  };
  final auth = <String, dynamic>{
    'username': 'user',
    'server': 'https://example.invalid',
    'private_key': 'old-private',
    'public_key': 'old-public',
    'code': 'otp-seed',
    'device_id': 'device-id',
    'device_name': 'device-name',
  };

  Map<String, dynamic> config() => {
    'proxies': <dynamic>[{'name': 'Airport-A', 'type': 'socks5'}],
    'proxy-groups': <dynamic>[
      {'name': 'OpenAI', 'type': 'select', 'proxies': <dynamic>['Airport-A']},
    ],
    'rules': <dynamic>[
      'RULE-SET,fuzhou-provider,FUZHOU-NODE-1',
      'MATCH,DIRECT',
    ],
  };

  void apply(Map<String, dynamic> raw, {
    List<CorplinkNodeSelection> nodes = selections,
    Map<String, dynamic>? currentAuth,
    String? cookies = '/private/cookies.json',
  }) {
    mergeCorplinkNodeOverlay(
      raw,
      settings: settings,
      selections: nodes,
      keyPairs: keyPairs,
      auth: currentAuth ?? auth,
      cookiePath: cookies,
      controlIP: '203.0.113.8',
    );
  }

  test('two independent nodes, exact-name groups and legacy alias are idempotent', () {
    final raw = config();
    apply(raw);
    apply(raw);

    final proxies = raw['proxies'] as List;
    final groups = raw['proxy-groups'] as List;
    expect(proxies.map((p) => p['name']),
        ['Airport-A', 'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG']);
    for (final name in ['FZ-INT-Node', 'FUZHOU-NODE-1']) {
      final proxy = proxies.singleWhere((p) => p['name'] == '$name-WG');
      expect(proxy['corplink']['corplink-vpn-server-name'], name);
      final group = groups.singleWhere((g) => g['name'] == name);
      expect(group['proxies'], ['$name-WG']);
    }
    expect(proxies.singleWhere((p) => p['name'] == 'FZ-INT-Node-WG')['private-key'],
        'intl-private');
    expect(proxies.singleWhere((p) => p['name'] == 'FUZHOU-NODE-1-WG')['private-key'],
        'fuzhou-private');
    expect(groups.singleWhere((g) => g['name'] == 'SG-Node')['proxies'],
        ['FZ-INT-Node']);
    expect(groups.singleWhere((g) => g['name'] == 'SG-OpenAI')['proxies'].first,
        'SG-Node');
    expect((raw['rules'] as List).where((r) =>
        r == 'RULE-SET,fuzhou-provider,FUZHOU-NODE-1').length, 1);
    expect((raw['rules'] as List).last, 'MATCH,DIRECT');
  });

  test('missing authorization and disabled selection fail closed per group', () {
    final raw = config();
    mergeCorplinkNodeOverlay(
      raw,
      settings: settings,
      selections: const [
        CorplinkNodeSelection(serverName: 'FZ-INT-Node'),
        CorplinkNodeSelection(serverName: 'FUZHOU-NODE-1', enabled: false),
      ],
      keyPairs: keyPairs,
    );
    final groups = raw['proxy-groups'] as List;
    expect(groups.singleWhere((g) => g['name'] == 'FZ-INT-Node')['proxies'], ['REJECT']);
    expect(groups.singleWhere((g) => g['name'] == 'FUZHOU-NODE-1')['proxies'], ['REJECT']);
    expect((raw['proxies'] as List).map((p) => p['name']), ['Airport-A']);
  });

  test('a downloaded name collision is rejected before touching the config', () {
    final raw = config();
    (raw['proxy-groups'] as List).add({
      'name': 'FUZHOU-NODE-1',
      'type': 'select',
      'proxies': <dynamic>['Airport-A'],
    });
    final before = raw.toString();
    expect(() => apply(raw), throwsStateError);
    expect(raw.toString(), before);
  });

  test('a downloaded fail-closed group is not mistaken for our managed group', () {
    final raw = config();
    (raw['proxy-groups'] as List).add({
      'name': 'FUZHOU-NODE-1',
      'type': 'select',
      'proxies': <dynamic>['REJECT'],
    });
    final before = raw.toString();
    expect(() => apply(raw), throwsStateError);
    expect(raw.toString(), before);
  });

  test('a downloaded same-name WireGuard proxy is not silently replaced', () {
    final raw = config();
    (raw['proxies'] as List).add({
      'name': 'FUZHOU-NODE-1-WG',
      'type': 'wireguard',
      'corplink': {'corplink-vpn-server-name': 'FUZHOU-NODE-1'},
    });
    final before = raw.toString();
    expect(() => apply(raw), throwsStateError);
    expect(raw.toString(), before);
  });

  test('case-folded downloaded name collisions are rejected', () {
    final raw = config();
    (raw['proxy-groups'] as List).add({
      'name': 'fuzhou-node-1',
      'type': 'select',
      'proxies': <dynamic>['REJECT'],
    });
    final before = raw.toString();
    expect(() => apply(raw), throwsStateError);
    expect(raw.toString(), before);
  });

  test('trusted first-pass groups survive a script returning a new map', () {
    final original = config();
    apply(original);
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(original)) as Map);
    mergeCorplinkNodeOverlay(
      afterScript,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: {
        'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      },
      trustedManagedProxyNames: {
        'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
      },
    );
    expect((afterScript['proxy-groups'] as List)
        .where((group) => group['name'] == 'FUZHOU-NODE-1').length, 1);
  });

  test('script-modified managed group fails closed without changing sibling', () {
    final raw = config();
    apply(raw);
    final expected = <String, dynamic>{
      for (final item in [
        ...(raw['proxy-groups'] as List),
        ...(raw['proxies'] as List),
      ])
        if (item is Map &&
            {'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
              'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG'}.contains(item['name']))
          item['name'] as String: jsonDecode(jsonEncode(item)),
    };
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(raw)) as Map);
    final group = (afterScript['proxy-groups'] as List).singleWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1') as Map;
    group['proxies'] = <String>['Airport-A'];
    final conflicts = <String>{};
    mergeCorplinkNodeOverlay(
      afterScript,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: {
        'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      },
      trustedManagedProxyNames: {
        'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
      },
      expectedManagedObjects: expected,
      onScriptConflict: conflicts.addAll,
    );
    expect(conflicts, contains('FUZHOU-NODE-1'));
    final groups = afterScript['proxy-groups'] as List;
    expect(groups.singleWhere((item) => item['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['REJECT']);
    expect(groups.singleWhere((item) => item['name'] == 'FZ-INT-Node')['proxies'],
        ['FZ-INT-Node-WG']);
    expect(groups.singleWhere((item) => item['name'] == 'OpenAI')['proxies'],
        contains('Airport-A'));
    expect((afterScript['proxies'] as List).where((item) =>
        item['name'] == 'FUZHOU-NODE-1-WG'), isEmpty);
  });

  test('script-modified managed proxy cannot silently redirect node traffic', () {
    final raw = config();
    apply(raw);
    final expected = <String, dynamic>{
      for (final item in [
        ...(raw['proxy-groups'] as List),
        ...(raw['proxies'] as List),
      ])
        if (item is Map && item['name'] is String)
          item['name'] as String: jsonDecode(jsonEncode(item)),
    };
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(raw)) as Map);
    final proxy = (afterScript['proxies'] as List).singleWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1-WG') as Map;
    proxy['server'] = 'different.example.invalid';
    final conflicts = <String>{};
    mergeCorplinkNodeOverlay(
      afterScript,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: {
        'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      },
      trustedManagedProxyNames: {
        'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
      },
      expectedManagedObjects: expected,
      onScriptConflict: conflicts.addAll,
    );
    expect(conflicts, contains('FUZHOU-NODE-1-WG'));
    expect((afterScript['proxy-groups'] as List)
        .singleWhere((item) => item['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['REJECT']);
    expect((afterScript['proxies'] as List)
        .where((item) => item['name'] == 'FUZHOU-NODE-1-WG'), isEmpty);
  });

  test('changing selected server removes obsolete generated node and group', () {
    final raw = config();
    apply(raw);
    apply(raw, nodes: const [CorplinkNodeSelection(serverName: 'FZ-INT-Node')]);
    expect((raw['proxies'] as List).where((p) =>
        p['name'] == 'FUZHOU-NODE-1-WG'), isEmpty);
    expect((raw['proxy-groups'] as List).where((g) =>
        g['name'] == 'FUZHOU-NODE-1'), isEmpty);
    expect((raw['rules'] as List), contains('RULE-SET,fuzhou-provider,FUZHOU-NODE-1'));
  });

  test('legacy SG alias follows the discovered INTL spelling', () {
    final raw = config();
    mergeCorplinkNodeOverlay(
      raw,
      settings: settings,
      selections: const [
        CorplinkNodeSelection(serverName: 'FUZHOU_INTL_node'),
        CorplinkNodeSelection(serverName: 'FUZHOU-NODE-1'),
      ],
      keyPairs: const {
        'FUZHOU_INTL_node': CorplinkNodeKeyPair(
          publicKey: 'intl-public', privateKey: 'intl-private'),
        'FUZHOU-NODE-1': CorplinkNodeKeyPair(
          publicKey: 'fuzhou-public', privateKey: 'fuzhou-private'),
      },
      auth: auth,
      cookiePath: '/private/cookies.json',
    );
    final groups = raw['proxy-groups'] as List;
    expect(groups.singleWhere((g) => g['name'] == 'SG-Node')['proxies'],
        ['FUZHOU_INTL_node']);
    expect(groups.singleWhere((g) => g['name'] == 'SG-OpenAI')['proxies'].first,
        'SG-Node');
  });

  test('SG alias prefers enabled INTL spelling when both aliases exist', () {
    final raw = config();
    mergeCorplinkNodeOverlay(
      raw,
      settings: settings,
      selections: const [
        CorplinkNodeSelection(serverName: 'FZ-INT-Node', enabled: false),
        CorplinkNodeSelection(serverName: 'FUZHOU_INTL_node'),
      ],
      keyPairs: const {
        'FUZHOU_INTL_node': CorplinkNodeKeyPair(
          publicKey: 'intl-public', privateKey: 'intl-private'),
      },
      auth: auth,
      cookiePath: '/private/cookies.json',
    );
    final groups = raw['proxy-groups'] as List;
    expect(groups.singleWhere((g) => g['name'] == 'SG-Node')['proxies'],
        ['FUZHOU_INTL_node']);
  });

  test('generated node and group names cannot collide with each other', () {
    final raw = config();
    final before = raw.toString();
    expect(() => mergeCorplinkNodeOverlay(
      raw,
      settings: settings,
      selections: const [
        CorplinkNodeSelection(serverName: 'A'),
        CorplinkNodeSelection(serverName: 'A-WG'),
      ],
      keyPairs: const {},
    ), throwsStateError);
    expect(raw.toString(), before);
  });
}
