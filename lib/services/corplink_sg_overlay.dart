import 'dart:convert';

import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/models/models.dart';
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

bool requiresCorplinkScriptSafetyFallback(
  Map<String, dynamic> scriptConfig, {
  required Set<String> trustedManagedProxyNames,
  required Set<String> originalProxyNames,
  required Map<String, dynamic> expectedManagedObjects,
}) {
  if (trustedManagedProxyNames.isEmpty) {
    return false;
  }
  final current = <String, dynamic>{
    for (final item in scriptConfig['proxies'] as List? ?? const [])
      if (item is Map && item['name'] is String)
        item['name'] as String: item,
  };
  final expectedNames = trustedManagedProxyNames
      .where(expectedManagedObjects.containsKey).toSet();
  for (final name in expectedNames) {
    if (current.containsKey(name) &&
        !_managedObjectEquality.equals(current[name], expectedManagedObjects[name])) {
      return true;
    }
  }
  final missing = expectedNames.difference(current.keys.toSet());
  if (missing.isEmpty) return false;
  if (expectedNames.intersection(current.keys.toSet()).isNotEmpty) {
    return true;
  }
  // Replacing an entire proxy list without new names is recoverable. New
  // names cannot be proven independent of a renamed managed proxy.
  return originalProxyNames.isNotEmpty &&
      current.keys.toSet().difference(originalProxyNames).isNotEmpty;
}

Map<String, dynamic> failClosedCorplinkScriptResult(
  Map<String, dynamic> preScriptConfig,
) {
  final safe = Map<String, dynamic>.from(
    jsonDecode(jsonEncode(preScriptConfig)) as Map,
  );
  // We cannot know what a removed/renamed managed proxy was changed into.
  // Drop the entire script result, including its sub-rules and dialer-proxy
  // references, and block all destinations until the script is corrected.
  safe['rules'] = <dynamic>['MATCH,REJECT'];
  safe['mode'] = 'rule';
  safe.remove('rule');
  return safe;
}

bool _isLegacyProxy(dynamic item) =>
    item is Map &&
    item['name'] == 'SG-Node' &&
    item['type'] == 'wireguard' &&
    item['corplink'] is Map;

bool _isManagedOpenAiRule(dynamic rule) {
  if (rule is! String) return false;
  final parsed = ParsedRule.parseString(rule);
  final target = parsed.ruleTarget;
  if (target == null ||
      (target != 'SG-OpenAI' && !isIntlCorplinkServerName(target))) {
    return false;
  }
  return corplinkOpenAiRules.contains(
    parsed.copyWith(ruleTarget: 'SG-OpenAI').value,
  );
}

Set<String> _pruneUnavailableNodeReferences(
  List<dynamic> proxies,
  List<dynamic> groups,
  List<dynamic> rules,
  Map<String, dynamic> config,
  Set<String> managedCandidates,
) {
  final present = <String>{
    for (final item in [...proxies, ...groups])
      if (item is Map && item['name'] is String) item['name'] as String,
  };
  final unavailable = managedCandidates.difference(present);
  final blocked = <String>{};
  var changed = true;
  while (changed) {
    changed = false;
    for (final item in List<dynamic>.from(proxies)) {
      if (item is! Map || item['name'] is! String) continue;
      if (unavailable.contains(item['dialer-proxy'])) {
        proxies.remove(item);
        unavailable.add(item['name'] as String);
        blocked.add(item['name'] as String);
        changed = true;
      }
    }
    for (final item in List<dynamic>.from(groups)) {
      if (item is! Map || item['name'] is! String) continue;
      final members = item['proxies'];
      if (members is! List) continue;
      if (members.any(unavailable.contains)) {
        // Dropping just the unavailable member can make a protected group
        // silently select DIRECT or an unrelated airport instead.
        item['proxies'] = <String>['REJECT'];
        if (item['use'] is List) item['use'] = <String>[];
        blocked.add(item['name'] as String);
      }
    }
  }

  String blockUnavailableTarget(String rawRule) {
    final parsed = ParsedRule.parseString(rawRule);
    if (!unavailable.contains(parsed.ruleTarget)) return rawRule;
    blocked.add(parsed.ruleTarget!);
    return parsed.copyWith(ruleTarget: 'REJECT').value;
  }

  for (var index = 0; index < rules.length; index++) {
    if (rules[index] is String) {
      rules[index] = blockUnavailableTarget(rules[index] as String);
    }
  }
  final subRules = config['sub-rules'];
  if (subRules is Map) {
    for (final key in subRules.keys.toList()) {
      final value = subRules[key];
      if (value is List<String>) {
        subRules[key] = value.map(blockUnavailableTarget).toList();
      } else if (value is List) {
        subRules[key] = <dynamic>[
          for (final rule in value)
            if (rule is String) blockUnavailableTarget(rule) else rule,
        ];
      }
    }
  }
  return blocked;
}

/// Adds one WireGuard outbound and one same-name select group per server.
/// All collision checks happen before any write to [rawConfig].
Set<String> mergeCorplinkNodeOverlay(
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
  void Function(Set<String>)? onUnavailableReferences,
}) {
  if (!settings.enabled) return <String>{};
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
  final plannedGroups = <String>{
    for (final selection in selections)
      if (selection.enabled) selection.serverName.toLowerCase(),
  };
  final plannedProxies = <String>{
    for (final selection in selections)
      if (selection.enabled) '${selection.serverName}-WG'.toLowerCase(),
  };
  if (plannedGroups.intersection(plannedProxies).isNotEmpty) {
    throw StateError('CORPLINK_GENERATED_NAME_COLLISION');
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
  if (requiresCorplinkScriptSafetyFallback(
    rawConfig,
    trustedManagedProxyNames: trustedProxyNames,
    originalProxyNames: originalProxyNames,
    expectedManagedObjects: expected,
  )) {
    throw StateError('CORPLINK_SCRIPT_PROXY_PROVENANCE_AMBIGUOUS');
  }
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
  final activeNames = <String>{
    for (final selection in selections)
      if (selection.enabled &&
          !suppressedNames.contains(selection.serverName) &&
          !scriptSuppressedNames.contains(selection.serverName) &&
          authorized &&
          keyPairs.containsKey(selection.serverName))
        selection.serverName,
  };
  final targetProxyNames = <String>{for (final name in activeNames) '$name-WG'};
  final targetGroupNames = <String>{...activeNames};
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

  final suppressedProxyNames = <String>{
    for (final name in scriptSuppressedNames) '$name-WG',
    for (final item in sourceProxies)
      if (item is Map &&
          item['name'] is String &&
          item['corplink'] is Map &&
          scriptSuppressedNames.contains(
              (item['corplink'] as Map)['corplink-vpn-server-name']))
        item['name'] as String,
  };
  String? intlName;
  for (final selection in selections) {
    if (activeNames.contains(selection.serverName) &&
        isIntlCorplinkServerName(selection.serverName)) {
      intlName = selection.serverName;
      break;
    }
  }

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
        if (name.toLowerCase() == 'fuzhou-node-1')
          'corplink-use-vpn-dns': true,
        if (selection.healthUrl.isNotEmpty)
          'corplink-health-host': Uri.parse(selection.healthUrl).host,
        'corplink-refresh-threshold-hours': 48,
        'corplink-refresh-hour': 3,
      },
    });
  }
  final groups = <dynamic>[];
  for (final item in sourceGroups) {
    if (item is! Map) {
      groups.add(item);
      continue;
    }
    final name = item['name']?.toString() ?? '';
    if (managedGroupNames.contains(name)) continue;
    final group = Map<String, dynamic>.from(item);
    groups.add(group);
  }
  for (final selection in selections) {
    final name = selection.serverName;
    if (!activeNames.contains(name)) continue;
    final probeUrl = effectiveCorplinkNodeProbeUrl(selection);
    groups.add({
      'name': name,
      'type': 'select',
      'proxies': <String>['$name-WG'],
      if (probeUrl.isNotEmpty) 'url': probeUrl,
    });
  }

  final rulesKey = rawConfig['rules'] is List ? 'rules' : 'rule';
  final rules = List<dynamic>.from(rawConfig[rulesKey] as List? ?? const []);
  rules.removeWhere(_isManagedOpenAiRule);
  final skippedReferences = _pruneUnavailableNodeReferences(
    proxies,
    groups,
    rules,
    rawConfig,
    {
      for (final name in selectionNames) name,
      for (final name in selectionNames) '$name-WG',
      ...trustedNames,
      ...trustedProxyNames,
      'SG-Node',
      'SG-OpenAI',
    },
  );
  rawConfig['proxies'] = proxies;
  rawConfig['proxy-groups'] = groups;
  rawConfig[rulesKey] = settings.routeOpenAi && intlName != null
      ? <dynamic>[
          for (final rule in corplinkOpenAiRules)
            rule.replaceFirst(RegExp(r'SG-OpenAI$'), intlName),
          ...rules,
        ]
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
  if (skippedReferences.isNotEmpty) {
    onUnavailableReferences?.call(Set.unmodifiable(skippedReferences));
  }
  return {...targetGroupNames, ...targetProxyNames};
}
