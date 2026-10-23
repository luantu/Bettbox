import 'dart:convert';

import 'network_matcher.dart';

enum SmartNetworkMatch { match, noMatch, unknown }
enum SmartNetworkAction { none, stop, resume, clearStopped }

/// Local-only settings. SSIDs are exact identifiers, not comma-separated rules.
class SmartNetworkRule {
  const SmartNetworkRule({required this.id, required this.name,
    this.enabled = true, this.ssid = '', this.networks = ''});

  final String id;
  final String name;
  final bool enabled;
  final String ssid;
  final String networks;

  String? get validationError {
    if (name.trim().isEmpty) return '请填写地点名称';
    if (ssid.trim().isEmpty && networks.trim().isEmpty) {
      return '请填写 SSID 或 IP／网关条件';
    }
    if (ssid.toLowerCase() == '<unknown ssid>') return '不能使用未知的 SSID';
    if (networks.trim().isNotEmpty && !NetworkMatcher.isValidRules(networks)) {
      return 'IP／网关格式错误，最多 5 条，用英文逗号分隔';
    }
    return null;
  }

  SmartNetworkRule withEnabled(bool value) => SmartNetworkRule(
    id: id, name: name, enabled: value, ssid: ssid, networks: networks);

  Map<String, Object> toJson() => {'id': id, 'name': name, 'enabled': enabled,
    'ssid': ssid, 'networks': networks};

  static String encode(List<SmartNetworkRule> rules) =>
    jsonEncode(rules.map((rule) => rule.toJson()).toList());

  static List<SmartNetworkRule> decode(String source) {
    if (source.trim().isEmpty) return const [];
    final value = jsonDecode(source);
    if (value is! List) throw const FormatException('地点规则必须是列表');
    return value.map((item) {
      if (item is! Map || item['id'] is! String || item['name'] is! String ||
          (item['enabled'] != null && item['enabled'] is! bool) ||
          (item['ssid'] != null && item['ssid'] is! String) ||
          (item['networks'] != null && item['networks'] is! String)) {
        throw const FormatException('地点规则格式错误');
      }
      final rule = SmartNetworkRule(id: item['id'] as String,
        name: item['name'] as String, enabled: item['enabled'] as bool? ?? true,
        ssid: item['ssid'] as String? ?? '',
        networks: item['networks'] as String? ?? '');
      if (rule.enabled && rule.validationError != null) {
        throw FormatException(rule.validationError!);
      }
      return rule;
    }).toList();
  }
}

class SmartNetworkSnapshot {
  const SmartNetworkSnapshot({required this.id, required this.selected,
    required this.transport, this.ssid, this.ssidStatus = 'notWifi',
    this.ips = const [], this.gateways = const []});

  final String id;
  final bool selected;
  final String transport;
  final String? ssid;
  final String ssidStatus;
  final List<String> ips;
  final List<String> gateways;

  bool get ssidAvailable => transport == 'wifi' && ssidStatus == 'available' &&
    ssid != null && ssid!.isNotEmpty && ssid!.toLowerCase() != '<unknown ssid>';

  static List<SmartNetworkSnapshot> decode(Map<dynamic, dynamic>? value) {
    final records = value?['networks'];
    if (records is! List) return const [];
    return records.whereType<Map>().where((item) =>
      const ['wifi', 'cellular', 'ethernet', 'other'].contains(item['transport']))
      .map((item) => SmartNetworkSnapshot(id: item['id']?.toString() ?? '',
        selected: item['selected'] == true, transport: item['transport'] as String,
        ssid: item['ssid'] is String ? item['ssid'] as String : null,
        ssidStatus: item['ssidStatus'] as String? ?? 'unavailable',
        ips: (item['ips'] as List?)?.whereType<String>().toList() ?? const [],
        gateways: (item['gateways'] as List?)?.whereType<String>().toList() ?? const []))
      .toList();
  }
}

class SmartNetworkDecision {
  const SmartNetworkDecision(this.match, this.reason);
  final SmartNetworkMatch match;
  final String reason;

  SmartNetworkAction action({required bool isSmartStopped,
    required bool isRunning, required bool? userRunIntent,
    bool compatibilityPaused = false}) {
    if (compatibilityPaused) return SmartNetworkAction.none;
    if (userRunIntent == false) {
      return isSmartStopped ? SmartNetworkAction.clearStopped : SmartNetworkAction.none;
    }
    if (match == SmartNetworkMatch.unknown) return SmartNetworkAction.none;
    if (match == SmartNetworkMatch.match && !isSmartStopped && isRunning) {
      return SmartNetworkAction.stop;
    }
    if (match == SmartNetworkMatch.noMatch && isSmartStopped) {
      return SmartNetworkAction.resume;
    }
    return SmartNetworkAction.none;
  }
}

class SmartNetworkPolicy {
  static bool _addressMatches(SmartNetworkSnapshot network, String conditions) =>
    network.ips.any((ip) => NetworkMatcher.matchAny(ip, conditions)) ||
    network.gateways.any((ip) => NetworkMatcher.matchAnyGateway(ip, conditions));

  static SmartNetworkDecision evaluate({required List<SmartNetworkSnapshot> networks,
    String rulesJson = '', String legacyNetworks = '', bool enabled = true}) {
    if (!enabled) return const SmartNetworkDecision(SmartNetworkMatch.noMatch, '智能启停已关闭');
    // Explicit legacy rules retain their old OR semantics, visibly warned in UI.
    if (legacyNetworks.trim().isNotEmpty &&
        networks.any((network) => _addressMatches(network, legacyNetworks))) {
      return const SmartNetworkDecision(SmartNetworkMatch.match, '命中旧版 IP 规则');
    }
    List<SmartNetworkRule> rules;
    try {
      rules = SmartNetworkRule.decode(rulesJson).where((rule) => rule.enabled).toList();
    } catch (_) {
      return const SmartNetworkDecision(SmartNetworkMatch.unknown, '地点规则格式错误，请修正配置');
    }
    if (rules.isEmpty && legacyNetworks.trim().isEmpty) {
      return const SmartNetworkDecision(SmartNetworkMatch.noMatch, '没有启用的规则');
    }
    if (networks.isEmpty) {
      return const SmartNetworkDecision(SmartNetworkMatch.unknown, '暂无底层网络，保持当前状态');
    }
    var unknown = false;
    final selected = networks.where((network) => network.selected).toList();
    for (final rule in rules) {
      if (selected.isEmpty) { unknown = true; continue; }
      for (final network in selected) {
        if (rule.ssid.isNotEmpty && network.transport != 'wifi') continue;
        if (rule.networks.trim().isNotEmpty && !_addressMatches(network, rule.networks)) {
          if (network.ips.isEmpty && network.gateways.isEmpty) unknown = true;
          continue;
        }
        if (rule.ssid.isNotEmpty) {
          if (!network.ssidAvailable) { unknown = true; continue; }
          if (rule.ssid != network.ssid) continue;
        }
        return const SmartNetworkDecision(SmartNetworkMatch.match, '命中地点规则');
      }
    }
    if (legacyNetworks.trim().isNotEmpty &&
        networks.every((network) => network.ips.isEmpty && network.gateways.isEmpty)) {
      unknown = true;
    }
    return unknown
      ? const SmartNetworkDecision(SmartNetworkMatch.unknown, '网络身份暂不可读，保持当前状态')
      : const SmartNetworkDecision(SmartNetworkMatch.noMatch, '当前网络未命中暂停规则');
  }
}
