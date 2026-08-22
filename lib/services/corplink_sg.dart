import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

const corplinkSgEnabledKey = 'corplinkSg.enabled';
const corplinkSgUsernameKey = 'corplinkSg.username';
const corplinkSgPasswordKey = 'corplinkSg.password';
const corplinkSgServerKey = 'corplinkSg.server';

class CorplinkSgSettings {
  final bool enabled;
  final String username;
  final String password;
  final String server;

  const CorplinkSgSettings({
    this.enabled = false,
    this.username = '',
    this.password = '',
    this.server = '',
  });

  static Future<CorplinkSgSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return CorplinkSgSettings(
      enabled: prefs.getBool(corplinkSgEnabledKey) ?? false,
      username: prefs.getString(corplinkSgUsernameKey) ?? '',
      password: prefs.getString(corplinkSgPasswordKey) ?? '',
      server: prefs.getString(corplinkSgServerKey) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(corplinkSgEnabledKey, enabled);
    await prefs.setString(corplinkSgUsernameKey, username);
    await prefs.setString(corplinkSgPasswordKey, password);
    await prefs.setString(corplinkSgServerKey, server);
  }

  Future<void> disable() => CorplinkSgSettings(
    username: username,
    password: password,
    server: server,
  ).save();
}

Future<String> corplinkSgHomePath() =>
    appPath.homeDirPath.then((path) => joinPath(path, 'corplink-sg'));

String joinPath(String base, String child) =>
    '$base${Platform.pathSeparator}$child';

Future<Map<String, dynamic>?> loadCorplinkConfig() async {
  final path = joinPath(await corplinkSgHomePath(), 'config.json');
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final value = jsonDecode(await file.readAsString());
    return value is Map ? Map<String, dynamic>.from(value) : null;
  } catch (_) {
    return null;
  }
}

Future<void> applyCorplinkSgNode(Map<String, dynamic> rawConfig) async {
  final settings = await CorplinkSgSettings.load();
  if (!settings.enabled || settings.server.trim().isEmpty) return;

  final auth = await loadCorplinkConfig();
  if (auth == null) return;
  final proxies =
      (rawConfig['proxies'] as List?)?.cast<dynamic>() ?? <dynamic>[];
  const name = 'SG-Node-Linux';
  proxies.removeWhere((item) => item is Map && item['name'] == name);
  final home = await corplinkSgHomePath();
  final interfaceName = auth['interface_name']?.toString() ?? 'wgdevtest22';
  final cookiePath = joinPath(home, '${interfaceName}_cookies.json');
  final apiServer = settings.server.trim();
  final privateKey = auth['private_key']?.toString() ?? '';
  final publicKey = auth['public_key']?.toString() ?? '';
  final code = auth['code']?.toString() ?? '';
  if (privateKey.isEmpty || publicKey.isEmpty || code.isEmpty) return;

  proxies.add({
    'name': name,
    'type': 'wireguard',
    'ip': '0.0.0.0',
    'private-key': privateKey,
    'server': Uri.tryParse(apiServer)?.host ?? apiServer,
    'port': 34080,
    'public-key': publicKey,
    'allowed-ips': ['0.0.0.0/0'],
    'tcp': true,
    'udp': true,
    'mtu': 1400,
    'persistent-keepalive': 25,
    'remote-dns-resolve': true,
    'dns': ['https://8.8.8.8/dns-query', 'https://1.1.1.1/dns-query'],
    'corplink': {
      'corplink-api-server': apiServer,
      'corplink-code': code,
      'corplink-cookie-file': cookiePath,
      'corplink-device-id': auth['device_id']?.toString() ?? '',
      'corplink-device-name': auth['device_name']?.toString() ?? name,
      'corplink-public-key': publicKey,
      'corplink-refresh-threshold-hours': 48,
      'corplink-refresh-hour': 3,
    },
  });
  rawConfig['proxies'] = proxies;

  final groups =
      (rawConfig['proxy-groups'] as List?)?.cast<dynamic>() ?? <dynamic>[];
  for (final group in groups) {
    if (group is! Map) continue;
    final list = group['proxies'];
    if (list is List && group['name']?.toString().contains('OpenAI') == true) {
      if (!list.contains(name)) list.insert(0, name);
    }
  }
  rawConfig['proxy-groups'] = groups;
}
