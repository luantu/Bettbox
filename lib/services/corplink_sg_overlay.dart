import 'dart:convert';

import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:collection/collection.dart';

// Object identity is trustworthy for a second pass over the same map. When
// JavaScript returns a new map, state.dart passes the first pass's names
// explicitly; a downloaded group is never trusted by its shape alone.
final Expando<Set<String>> _generatedGroupsByConfig = Expando<Set<String>>();
final Expando<Set<String>> _generatedProxiesByConfig = Expando<Set<String>>();
final Expando<Map<String, dynamic>> _generatedSnapshotsByConfig =
    Expando<Map<String, dynamic>>();
const _managedObjectEquality = DeepCollectionEquality();

class CorplinkManagedNames {
  const CorplinkManagedNames({
    required this.groups,
    required this.proxies,
    required this.allProxyNames,
  });

  final Set<String> groups;
  final Set<String> proxies;
  final Set<String> allProxyNames;
}

CorplinkManagedNames captureCorplinkManagedNames(
  Map<String, dynamic> config,
  Set<String> generatedNames,
) {
  final proxies = <String>{
    for (final item in config['proxies'] as List? ?? const [])
      if (item is Map && item['name'] is String &&
          generatedNames.contains(item['name']))
        item['name'] as String,
  };
  final groups = <String>{
    for (final item in config['proxy-groups'] as List? ?? const [])
      if (item is Map && item['name'] is String &&
          generatedNames.contains(item['name']))
        item['name'] as String,
  };
  final allProxyNames = <String>{
    for (final item in config['proxies'] as List? ?? const [])
      if (item is Map && item['name'] is String) item['name'] as String,
  };
  return CorplinkManagedNames(
    groups: groups,
    proxies: proxies,
    allProxyNames: allProxyNames,
  );
}

bool _isLegacyProxy(dynamic item) =>
    item is Map &&
    item['name'] == 'SG-Node' &&
    item['type'] == 'wireguard' &&
    item['corplink'] is Map;

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
  Set<String> trustedManagedGroupNames = const {},
  Set<String> trustedManagedProxyNames = const {},
  Set<String> originalProxyNames = const {},
  Map<String, dynamic> expectedManagedObjects = const {},
  void Function(Set<String>)? onScriptConflict,
}) {
  if (!settings.enabled) return;
  final selectionNames = <String>{};
  final foldedNames = <String>{};
  var enabledIntl = 0;
  for (final selection in selections) {
    if (selection.validationError != null ||
        !selectionNames.add(selection.serverName) ||
        !foldedNames.add(selection.serverName.toLowerCase())) {
      throw StateError('INVALID_CORPLINK_NODE_SELECTION');
    }
    if (selection.enabled && isIntlCorplinkServerName(selection.serverName)) {
      enabledIntl++;
    }
  }
  if (enabledIntl > 1) {
    throw StateError('CORPLINK_DUPLICATE_INTL_ALIAS');
  }
  for (final name in selectionNames) {
    if (selectionNames.contains('$name-WG')) {
      throw StateError('CORPLINK_GENERATED_NAME_COLLISION');
    }
  }

  final sourceProxies = List<dynamic>.from(rawConfig['proxies'] as List? ?? const []);
  final sourceGroups = List<dynamic>.from(rawConfig['proxy-groups'] as List? ?? const []);
  final trustedNames = {
    ...trustedManagedGroupNames,
    ...?_generatedGroupsByConfig[rawConfig],
  };
  final trustedProxyNames = {
    ...trustedManagedProxyNames,
    ...?_generatedProxiesByConfig[rawConfig],
  };
  final managedProxyNames = <String>{
    for (final item in sourceProxies)
      if (item is Map && item['name'] is String &&
          trustedProxyNames.contains(item['name']))
        item['name'] as String,
  };
  final managedGroupNames = <String>{
    for (final item in sourceGroups)
      if (item is Map && item['name'] is String &&
          trustedNames.contains(item['name']))
        item['name'] as String,
  };
  final expected = {
    ...?_generatedSnapshotsByConfig[rawConfig],
    ...expectedManagedObjects,
  };
  final scriptConflicts = <String>{};
  final missingManagedProxyNames = <String>{};
  for (final item in [...sourceProxies, ...sourceGroups]) {
    if (item is! Map || item['name'] is! String) continue;
    final name = item['name'] as String;
    if (!managedProxyNames.contains(name) && !managedGroupNames.contains(name)) {
      continue;
    }
    if (expected.isNotEmpty &&
        (!expected.containsKey(name) ||
            !_managedObjectEquality.equals(item, expected[name]))) {
      scriptConflicts.add(name);
    }
  }
  if (expected.isNotEmpty) {
    // A script may replace the entire group/proxy list; in that case the
    // second pass restores managed entries as designed. A partial deletion
    // or rename, however, is an explicit change to one managed route.
    if (managedGroupNames.isNotEmpty) {
      scriptConflicts.addAll(
        trustedNames.where((name) =>
            expected.containsKey(name) && !managedGroupNames.contains(name)),
      );
    }
    if (managedProxyNames.isNotEmpty) {
      missingManagedProxyNames.addAll(
        trustedProxyNames.where((name) =>
            expected.containsKey(name) && !managedProxyNames.contains(name)),
      );
      scriptConflicts.addAll(missingManagedProxyNames);
    }
  }

  final targetProxyNames = <String>{for (final name in selectionNames) '$name-WG'};
  final targetGroupNames = <String>{...selectionNames, 'SG-Node', 'SG-OpenAI'};
  final foldedTargetProxyNames = targetProxyNames.map((name) => name.toLowerCase()).toSet();
  final foldedTargetGroupNames = targetGroupNames.map((name) => name.toLowerCase()).toSet();
  if (foldedTargetProxyNames.intersection(foldedTargetGroupNames).isNotEmpty) {
    throw StateError('CORPLINK_GENERATED_NAME_COLLISION');
  }
  final seenProxyNames = <String>{};
  for (final item in sourceProxies) {
    if (item is! Map || item['name'] is! String) continue;
    final name = item['name'] as String;
    if (!seenProxyNames.add(name)) throw StateError('DUPLICATE_PROXY_NAME');
    if (foldedTargetProxyNames.contains(name.toLowerCase()) &&
        !managedProxyNames.contains(name)) {
      throw StateError('CORPLINK_PROXY_NAME_COLLISION');
    }
    if (foldedTargetGroupNames.contains(name.toLowerCase()) &&
        !_isLegacyProxy(item)) {
      throw StateError('CORPLINK_GROUP_NAME_COLLISION');
    }
  }
  final seenGroupNames = <String>{};
  for (final item in sourceGroups) {
    if (item is! Map || item['name'] is! String) continue;
    final name = item['name'] as String;
    if (!seenGroupNames.add(name)) throw StateError('DUPLICATE_GROUP_NAME');
    if (foldedTargetProxyNames.contains(name.toLowerCase())) {
      throw StateError('CORPLINK_PROXY_NAME_COLLISION');
    }
    if (foldedTargetGroupNames.contains(name.toLowerCase()) &&
        name != 'SG-OpenAI' &&
        !managedGroupNames.contains(name)) {
      throw StateError('CORPLINK_GROUP_NAME_COLLISION');
    }
  }

  final authorized = settings.isConfigured &&
      corplinkAuthMatchesSettings(auth, settings) &&
      cookiePath != null &&
      cookiePath.isNotEmpty;
  final scriptSuppressedNames = <String>{
    for (final name in selectionNames)
      if (scriptConflicts.contains(name) ||
          scriptConflicts.contains('$name-WG'))
        name,
  };
  final ambiguousNewProxyNames = <String>{
    // Once a managed proxy disappears, a newly named proxy may be that
    // object with its CorpLink marker and type stripped by the script.
    // There is no reliable provenance left, so block new proxies in this
    // conflicted pass rather than allowing an unverified egress route.
    if (missingManagedProxyNames.isNotEmpty && originalProxyNames.isNotEmpty)
      for (final item in sourceProxies)
        if (item is Map &&
            item['name'] is String &&
            !originalProxyNames.contains(item['name']))
          item['name'] as String,
  };
  scriptConflicts.addAll(ambiguousNewProxyNames);
  final suppressedProxyNames = <String>{
    for (final name in scriptSuppressedNames) '$name-WG',
    ...ambiguousNewProxyNames,
    for (final item in sourceProxies)
      if (item is Map &&
          item['name'] is String &&
          item['corplink'] is Map &&
          scriptSuppressedNames.contains(
              (item['corplink'] as Map)['corplink-vpn-server-name']))
        item['name'] as String,
  };
  final activeNames = <String>{
    for (final selection in selections)
      if (selection.enabled &&
          !suppressedNames.contains(selection.serverName) &&
          !scriptSuppressedNames.contains(selection.serverName) &&
          authorized &&
          keyPairs.containsKey(selection.serverName))
        selection.serverName,
  };
  String? intlName;
  for (final selection in selections) {
    if (selection.enabled && isIntlCorplinkServerName(selection.serverName)) {
      intlName = selection.serverName;
      break;
    }
  }
  if (intlName == null) {
    for (final selection in selections) {
      if (isIntlCorplinkServerName(selection.serverName)) {
        intlName = selection.serverName;
        break;
      }
    }
  }
  final intlActive = intlName != null && activeNames.contains(intlName);
  final aliasConflict = scriptConflicts.contains('SG-Node');
  final openAiConflict = scriptConflicts.contains('SG-OpenAI');

  final proxies = <dynamic>[
    for (final item in sourceProxies)
      if (!(item is Map && managedProxyNames.contains(item['name'])) &&
          !(item is Map && suppressedProxyNames.contains(item['name'])) &&
          !_isLegacyProxy(item)) item,
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
    if (group['proxies'] is List && suppressedProxyNames.isNotEmpty) {
      group['proxies'] = [
        for (final member in group['proxies'] as List)
          if (suppressedProxyNames.contains(member)) 'REJECT' else member,
      ];
    }
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
      if (intlActive && !aliasConflict && !openAiConflict && settings.routeOpenAi) {
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
    'proxies': !aliasConflict && intlName != null
        ? <String>[intlName]
        : <String>['REJECT'],
  });
  groups.add({
    'name': 'SG-OpenAI',
    'type': 'select',
    'proxies': intlActive && !aliasConflict && !openAiConflict
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
  _generatedGroupsByConfig[rawConfig] = targetGroupNames;
  _generatedProxiesByConfig[rawConfig] = targetProxyNames;
  _generatedSnapshotsByConfig[rawConfig] = {
    for (final item in [...proxies, ...groups])
      if (item is Map &&
          (targetProxyNames.contains(item['name']) ||
              targetGroupNames.contains(item['name'])))
        item['name'] as String: jsonDecode(jsonEncode(item)),
  };
  if (scriptConflicts.isNotEmpty) {
    onScriptConflict?.call(Set.unmodifiable(scriptConflicts));
  }
}
