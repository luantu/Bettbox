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
    'rule-providers': <String, dynamic>{
      'fuzhou-provider': {
        'type': 'http', 'url': 'https://example.invalid/fuzhou-rules',
        'path': './fuzhou-rules.yaml', 'interval': 3600,
      },
    },
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
    final managed = captureCorplinkManagedNames(original, {
      'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
    });
    final expected = <String, dynamic>{
      for (final item in [
        ...(original['proxy-groups'] as List),
        ...(original['proxies'] as List),
      ])
        if (item is Map &&
            {...managed.groups, ...managed.proxies}.contains(item['name']))
          item['name'] as String: jsonDecode(jsonEncode(item)),
    };
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(original)) as Map);
    final conflicts = <String>{};
    mergeCorplinkNodeOverlay(
      afterScript,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: managed.groups,
      trustedManagedProxyNames: managed.proxies,
      originalProxyNames: managed.allProxyNames,
      expectedManagedObjects: expected,
      onScriptConflict: conflicts.addAll,
    );
    expect(conflicts, isEmpty);
    expect((afterScript['proxy-groups'] as List)
        .where((group) => group['name'] == 'FUZHOU-NODE-1').length, 1);
    expect((afterScript['proxy-groups'] as List)
        .singleWhere((group) => group['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['FUZHOU-NODE-1-WG']);
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

  test('partial script deletion of one managed group blocks only that node', () {
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
    (afterScript['proxy-groups'] as List).removeWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1');
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
  });

  test('direct rule targeting a suppressed WG proxy is rewritten to REJECT', () {
    final raw = config();
    apply(raw);
    final managed = captureCorplinkManagedNames(raw, {
      'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
    });
    final expected = <String, dynamic>{
      for (final item in [
        ...(raw['proxy-groups'] as List),
        ...(raw['proxies'] as List),
      ])
        if (item is Map &&
            {...managed.groups, ...managed.proxies}.contains(item['name']))
          item['name'] as String: jsonDecode(jsonEncode(item)),
    };
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(raw)) as Map);
    (afterScript['proxies'] as List).removeWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1-WG');
    (afterScript['rules'] as List).insert(0,
        'DOMAIN-SUFFIX,example.com,FUZHOU-NODE-1-WG');
    mergeCorplinkNodeOverlay(
      afterScript,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: managed.groups,
      trustedManagedProxyNames: managed.proxies,
      originalProxyNames: managed.allProxyNames,
      expectedManagedObjects: expected,
    );
    expect(afterScript['rules'], contains('DOMAIN-SUFFIX,example.com,REJECT'));
    expect((afterScript['proxy-groups'] as List)
        .singleWhere((item) => item['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['REJECT']);
  });

  test('whole-list script replacement still restores managed groups', () {
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
    afterScript['proxy-groups'] = <dynamic>[];
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
    expect(conflicts, isEmpty);
    final groups = afterScript['proxy-groups'] as List;
    expect(groups.singleWhere((item) => item['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['FUZHOU-NODE-1-WG']);
  });

  test('renamed managed group does not leave a dangling WG reference', () {
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
    final renamed = (afterScript['proxy-groups'] as List).singleWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1') as Map;
    renamed['name'] = 'Other';
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
    expect(groups.singleWhere((item) => item['name'] == 'Other')['proxies'],
        ['REJECT']);
    expect(groups.singleWhere((item) => item['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['REJECT']);
  });

  test('renamed proxy with removed CorpLink marker is still fail-closed', () {
    final raw = config();
    apply(raw);
    final managed = captureCorplinkManagedNames(raw, {
      'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
    });
    final expected = <String, dynamic>{
      for (final item in [
        ...(raw['proxy-groups'] as List),
        ...(raw['proxies'] as List),
      ])
        if (item is Map &&
            {...managed.groups, ...managed.proxies}.contains(item['name']))
          item['name'] as String: jsonDecode(jsonEncode(item)),
    };
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(raw)) as Map);
    final renamed = (afterScript['proxies'] as List).singleWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1-WG') as Map;
    renamed['name'] = 'Other-WG';
    renamed['type'] = 'socks5';
    renamed.remove('corplink');
    renamed['server'] = 'different.example.invalid';
    renamed['port'] = 1080;
    (afterScript['proxy-groups'] as List).add({
      'name': 'Other', 'type': 'select', 'proxies': <String>['Other-WG'],
    });
    expect(hasAmbiguousCorplinkScriptProxyChange(
      afterScript,
      trustedManagedProxyNames: managed.proxies,
      originalProxyNames: managed.allProxyNames,
      expectedManagedObjects: expected,
    ), isTrue);
    final before = afterScript.toString();
    expect(() => mergeCorplinkNodeOverlay(
      afterScript,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: managed.groups,
      trustedManagedProxyNames: managed.proxies,
      originalProxyNames: managed.allProxyNames,
      expectedManagedObjects: expected,
    ), throwsStateError);
    expect(afterScript.toString(), before);
  });

  test('ambiguous script fallback blocks all traffic and drops dangling refs', () {
    final original = config();
    apply(original);
    final managed = captureCorplinkManagedNames(original, {
      'FZ-INT-Node', 'FUZHOU-NODE-1', 'SG-Node', 'SG-OpenAI',
      'FZ-INT-Node-WG', 'FUZHOU-NODE-1-WG',
    });
    final expected = <String, dynamic>{
      for (final item in [
        ...(original['proxy-groups'] as List),
        ...(original['proxies'] as List),
      ])
        if (item is Map &&
            {...managed.groups, ...managed.proxies}.contains(item['name']))
          item['name'] as String: jsonDecode(jsonEncode(item)),
    };
    final afterScript = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(original)) as Map);
    (afterScript['proxies'] as List).removeWhere(
        (item) => item['name'] == 'FUZHOU-NODE-1-WG');
    (afterScript['proxies'] as List).add({
      'name': 'Airport-B', 'type': 'socks5',
      'server': 'airport.example.invalid', 'port': 1080,
    });
    (afterScript['rules'] as List).insert(0, 'DOMAIN-SUFFIX,example.com,Airport-B');
    afterScript['sub-rules'] = {
      'test': <String>['DOMAIN-SUFFIX,sub.example.com,Airport-B'],
    };
    (afterScript['proxies'] as List).add({
      'name': 'Relay', 'type': 'socks5',
      'server': 'relay.example.invalid', 'port': 1081,
      'dialer-proxy': 'Airport-B',
    });
    (afterScript['rule-providers'] as Map).addAll({
      'test-provider': {'type': 'http', 'url': 'https://example.invalid/rules',
        'path': './test-provider.yaml', 'interval': 3600},
    });
    (afterScript['rules'] as List).insert(0,
        'RULE-SET,test-provider,FUZHOU-NODE-1');
    expect(hasAmbiguousCorplinkScriptProxyChange(
      afterScript,
      trustedManagedProxyNames: managed.proxies,
      originalProxyNames: managed.allProxyNames,
      expectedManagedObjects: expected,
    ), isTrue);

    final safe = failClosedCorplinkScriptResult(original);
    mergeCorplinkNodeOverlay(
      safe,
      settings: settings,
      selections: selections,
      keyPairs: keyPairs,
      auth: auth,
      cookiePath: '/private/cookies.json',
      trustedManagedGroupNames: managed.groups,
      trustedManagedProxyNames: managed.proxies,
      originalProxyNames: managed.allProxyNames,
      expectedManagedObjects: expected,
      suppressedNames: {'FZ-INT-Node', 'FUZHOU-NODE-1'},
    );
    expect((safe['proxies'] as List).map((item) => item['name']), ['Airport-A']);
    expect(safe['rules'], contains('MATCH,REJECT'));
    expect(safe['rules'], isNot(contains('DOMAIN-SUFFIX,example.com,Airport-B')));
    expect(safe['sub-rules'], isNull);
    expect((safe['rule-providers'] as Map).containsKey('test-provider'), isFalse);
    expect((safe['proxy-groups'] as List)
        .singleWhere((item) => item['name'] == 'FUZHOU-NODE-1')['proxies'],
        ['REJECT']);
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

  test('generated proxy and group names cannot collide after case folding', () {
    final raw = config();
    final before = raw.toString();
    expect(() => mergeCorplinkNodeOverlay(
      raw,
      settings: settings,
      selections: const [
        CorplinkNodeSelection(serverName: 'A'),
        CorplinkNodeSelection(serverName: 'a-WG'),
      ],
      keyPairs: const {},
    ), throwsStateError);
    expect(raw.toString(), before);
  });
}
