import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';

bool _isManagedProxy(dynamic item) {
  if (item is! Map || item['type'] != 'wireguard') return false;
  final name = item['name'];
  final corplink = item['corplink'];
  return name is String &&
      name.endsWith('-WG') &&
      corplink is Map &&
      corplink['corplink-vpn-server-name'] ==
          name.substring(0, name.length - 3);
}

bool _isLegacyProxy(dynamic item) =>
    item is Map &&
    item['name'] == 'SG-Node' &&
    item['type'] == 'wireguard' &&
    item['corplink'] is Map;

bool _isManagedGroup(dynamic item, Set<String> knownNames) {
  if (item is! Map || item['type'] != 'select') return false;
  final name = item['name'];
  final members = item['proxies'];
  if (name is! String || members is! List) return false;
  if (name == 'SG-Node') {
    return item['hidden'] == true &&
        (members.length == 1 &&
            (members.single == 'FZ-INT-Node' || members.single == 'REJECT'));
  }
  return knownNames.contains(name) &&
      members.length == 1 &&
      (members.single == '$name-WG' || members.single == 'REJECT');
}

/// Adds one WireGuard outbound and one same-name select group per server.
/// All collision checks happen before any write to [rawConfig].
void mergeCorplinkNodeOverlay(
  Map<String, dynamic> rawConfig, {
  required CorplinkSgSettings settings,
  required List<CorplinkNodeSelection> selections,
  required Map<String, CorplinkNodeKeyPair> keyPairs,
  Map<String, dynamic>? auth,
  String? cookiePath,
  String? controlIP,
  Set<String> suppressedNames = const {},
}) {
  if (!settings.enabled) return;
  final selectionNames = <String>{};
  for (final selection in selections) {
    if (selection.validationError != null ||
        !selectionNames.add(selection.serverName)) {
      throw StateError('INVALID_CORPLINK_NODE_SELECTION');
    }
  }

  final sourceProxies = List<dynamic>.from(rawConfig['proxies'] as List? ?? const []);
  final sourceGroups = List<dynamic>.from(rawConfig['proxy-groups'] as List? ?? const []);
  final priorManagedNames = <String>{};
  for (final item in sourceProxies) {
    if (_isManagedProxy(item)) {
      priorManagedNames.add((item as Map)['corplink']['corplink-vpn-server-name'] as String);
    }
  }
  final knownNames = {...selectionNames, ...priorManagedNames};
  final managedProxyNames = <String>{
    for (final item in sourceProxies)
      if (_isManagedProxy(item)) (item as Map)['name'] as String,
  };
  final managedGroupNames = <String>{
    for (final item in sourceGroups)
      if (_isManagedGroup(item, knownNames)) (item as Map)['name'] as String,
  };

  final targetProxyNames = <String>{for (final name in selectionNames) '$name-WG'};
  final targetGroupNames = <String>{...selectionNames, 'SG-Node', 'SG-OpenAI'};
  final seenProxyNames = <String>{};
  for (final item in sourceProxies) {
    if (item is! Map || item['name'] is! String) continue;
    final name = item['name'] as String;
    if (!seenProxyNames.add(name)) throw StateError('DUPLICATE_PROXY_NAME');
    if (targetProxyNames.contains(name) && !managedProxyNames.contains(name)) {
      throw StateError('CORPLINK_PROXY_NAME_COLLISION');
    }
    if (targetGroupNames.contains(name) && !_isLegacyProxy(item)) {
      throw StateError('CORPLINK_GROUP_NAME_COLLISION');
    }
  }
  final seenGroupNames = <String>{};
  for (final item in sourceGroups) {
    if (item is! Map || item['name'] is! String) continue;
    final name = item['name'] as String;
    if (!seenGroupNames.add(name)) throw StateError('DUPLICATE_GROUP_NAME');
    if (targetProxyNames.contains(name)) {
      throw StateError('CORPLINK_PROXY_NAME_COLLISION');
    }
    if (targetGroupNames.contains(name) &&
        name != 'SG-OpenAI' &&
        !managedGroupNames.contains(name)) {
      throw StateError('CORPLINK_GROUP_NAME_COLLISION');
    }
  }

  final authorized = settings.isConfigured &&
      corplinkAuthMatchesSettings(auth, settings) &&
      cookiePath != null &&
      cookiePath.isNotEmpty;
  final activeNames = <String>{
    for (final selection in selections)
      if (selection.enabled &&
          !suppressedNames.contains(selection.serverName) &&
          authorized &&
          keyPairs.containsKey(selection.serverName))
        selection.serverName,
  };

  final proxies = <dynamic>[
    for (final item in sourceProxies)
      if (!_isManagedProxy(item) && !_isLegacyProxy(item)) item,
  ];
  final apiServer = settings.server.trim();
  for (final selection in selections) {
    final name = selection.serverName;
    if (!activeNames.contains(name)) continue;
    final keys = keyPairs[name]!;
    proxies.add({
      'name': '$name-WG',
      'type': 'wireguard',
      'ip': '0.0.0.0',
      'private-key': keys.privateKey,
      'server': Uri.parse(apiServer).host,
      'port': 34080,
      'public-key': keys.publicKey,
      'allowed-ips': ['0.0.0.0/0'],
      'tcp': true,
      'udp': true,
      'mtu': 1400,
      'persistent-keepalive': 25,
      'remote-dns-resolve': true,
      'dns': ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
      'corplink': {
        'corplink-api-server': apiServer,
        if (controlIP != null) 'corplink-control-ip': controlIP,
        'corplink-code': auth!['code']?.toString() ?? '',
        'corplink-cookie-file': cookiePath,
        'corplink-device-id': auth['device_id']?.toString() ?? '',
        'corplink-device-name': auth['device_name']?.toString() ?? 'SG-Node',
        'corplink-vpn-server-name': name,
        'corplink-public-key': keys.publicKey,
        'corplink-refresh-threshold-hours': 48,
        'corplink-refresh-hour': 3,
      },
    });
  }

  final groups = <dynamic>[];
  String? primarySubscriptionGroup;
  final openAiGroup = RegExp(r'openai|chatgpt', caseSensitive: false);
  for (final item in sourceGroups) {
    if (item is! Map) {
      groups.add(item);
      continue;
    }
    final name = item['name']?.toString() ?? '';
    if (name == 'SG-OpenAI' || managedGroupNames.contains(name)) continue;
    final group = Map<String, dynamic>.from(item);
    final kind = group['type']?.toString().toLowerCase();
    if (primarySubscriptionGroup == null &&
        name != 'GLOBAL' &&
        !openAiGroup.hasMatch(name) &&
        {'select', 'url-test', 'fallback', 'load-balance'}.contains(kind)) {
      primarySubscriptionGroup = name;
    }
    if (group['proxies'] is List &&
        (name == 'GLOBAL' || openAiGroup.hasMatch(name))) {
      final members = List<dynamic>.from(group['proxies'] as List);
      members.removeWhere((member) => member == 'SG-Node');
      if (activeNames.contains('FZ-INT-Node') && settings.routeOpenAi) {
        members.insert(0, 'SG-Node');
      }
      if (members.isEmpty) members.add('REJECT');
      group['proxies'] = members;
    }
    groups.add(group);
  }
  for (final selection in selections) {
    final name = selection.serverName;
    groups.add({
      'name': name,
      'type': 'select',
      'proxies': activeNames.contains(name) ? <String>['$name-WG'] : <String>['REJECT'],
    });
  }
  groups.add({
    'name': 'SG-Node',
    'type': 'select',
    'hidden': true,
    'proxies': selectionNames.contains('FZ-INT-Node')
        ? <String>['FZ-INT-Node']
        : <String>['REJECT'],
  });
  groups.add({
    'name': 'SG-OpenAI',
    'type': 'select',
    'proxies': activeNames.contains('FZ-INT-Node')
        ? <String>['SG-Node', if (primarySubscriptionGroup != null) primarySubscriptionGroup]
        : <String>['REJECT'],
  });

  final rulesKey = rawConfig['rules'] is List ? 'rules' : 'rule';
  final rules = List<dynamic>.from(rawConfig[rulesKey] as List? ?? const []);
  rules.removeWhere((rule) => rule is String && corplinkOpenAiRules.contains(rule));
  rawConfig['proxies'] = proxies;
  rawConfig['proxy-groups'] = groups;
  rawConfig[rulesKey] = settings.routeOpenAi
      ? <dynamic>[...corplinkOpenAiRules, ...rules]
      : rules;
  rawConfig.remove(rulesKey == 'rules' ? 'rule' : 'rules');
}
