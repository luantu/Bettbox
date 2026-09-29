import 'dart:convert';

import 'package:bett_box/services/corplink_sg.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _selectionPreferenceKey = 'corplinkSg.nodeSelections.v1';
const _secretPrefix = 'corplinkSg.nodes.v1';
const _secureStorage = FlutterSecureStorage();

bool isIntlCorplinkServerName(String serverName) {
  final canonical = serverName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return canonical == 'fzintnode' || canonical == 'fuzhouintlnode';
}

abstract class CorplinkNodeSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class _PlatformNodeSecrets implements CorplinkNodeSecretStore {
  const _PlatformNodeSecrets();

  @override
  Future<String?> read(String key) => _secureStorage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _secureStorage.write(key: key, value: value);
}

class CorplinkNodeSelection {
  final String serverName;
  final bool enabled;
  final String healthUrl;

  const CorplinkNodeSelection({
    required this.serverName,
    this.enabled = true,
    this.healthUrl = '',
  });

  String? get validationError {
    const reservedNames = {
      'SG-NODE', 'SG-OPENAI', 'DIRECT', 'REJECT', 'REJECT-DROP',
      'COMPATIBLE', 'GLOBAL', 'PASS', 'PASS-RULE',
    };
    if (serverName.isEmpty ||
        serverName.trim() != serverName ||
        RegExp(r'[:,/\\?#@\r\n\x00-\x1f]').hasMatch(serverName) ||
        reservedNames.contains(serverName.toUpperCase())) {
      return '服务器节点名称无效';
    }
    if (healthUrl.isEmpty) return null;
    final uri = Uri.tryParse(healthUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return '健康探测地址必须是不含账号和片段的 HTTPS 地址';
    }
    return null;
  }
}

class CorplinkNodeKeyPair {
  final String publicKey;
  final String privateKey;

  const CorplinkNodeKeyPair({required this.publicKey, required this.privateKey});
}

String _nodeSecretKey(String username, String server, String serverName) {
  final scope = jsonEncode([
    username.trim(),
    server.trim().replaceFirst(RegExp(r'/$'), ''),
    serverName,
  ]);
  return '$_secretPrefix.${sha256.convert(utf8.encode(scope))}';
}

Future<CorplinkNodeKeyPair> loadOrCreateCorplinkNodeKeyPair(
  CorplinkSgSettings settings,
  String serverName, {
  CorplinkNodeSecretStore? secrets,
  Map<String, dynamic>? legacyAuth,
}) async {
  final selection = CorplinkNodeSelection(serverName: serverName);
  if (selection.validationError != null) {
    throw ArgumentError.value(serverName, 'serverName', selection.validationError);
  }
  final store = secrets ?? const _PlatformNodeSecrets();
  final key = _nodeSecretKey(settings.username, settings.server, serverName);
  final stored = await store.read(key);
  if (stored != null) {
    try {
      final decoded = jsonDecode(stored);
      if (decoded is Map &&
          decoded['publicKey'] is String &&
          decoded['privateKey'] is String) {
        return CorplinkNodeKeyPair(
          publicKey: decoded['publicKey'] as String,
          privateKey: decoded['privateKey'] as String,
        );
      }
    } catch (_) {
      // A damaged key record is not usable. A fresh key is generated below.
    }
  }

  CorplinkNodeKeyPair pair;
  if (isIntlCorplinkServerName(serverName) &&
      corplinkAuthMatchesSettings(legacyAuth, settings)) {
    pair = CorplinkNodeKeyPair(
      publicKey: legacyAuth!['public_key'] as String,
      privateKey: legacyAuth['private_key'] as String,
    );
  } else {
    final generated = await X25519().newKeyPair();
    pair = CorplinkNodeKeyPair(
      publicKey: base64Encode((await generated.extractPublicKey()).bytes),
      privateKey: base64Encode(await generated.extractPrivateKeyBytes()),
    );
  }
  await store.write(key, jsonEncode({
    'publicKey': pair.publicKey,
    'privateKey': pair.privateKey,
  }));
  return pair;
}

String _probeSecretKey(String username, String upstream, String serverName) =>
    '$_secretPrefix.probe.${sha256.convert(utf8.encode(jsonEncode([
      username.trim(),
      upstream.trim().replaceFirst(RegExp(r'/$'), ''),
      serverName,
    ])))}';

Future<List<CorplinkNodeSelection>?> loadCorplinkNodeSelections({
  CorplinkNodeSecretStore? secrets,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_selectionPreferenceKey);
  if (raw == null) return null;
  final username = prefs.getString(corplinkSgUsernameKey) ?? '';
  final upstream = prefs.getString(corplinkSgServerKey) ?? '';
  final store = secrets ?? const _PlatformNodeSecrets();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final selections = <CorplinkNodeSelection>[];
    for (final item in decoded) {
      if (item is! Map || item['serverName'] is! String) continue;
      final name = item['serverName'] as String;
      final selection = CorplinkNodeSelection(
        serverName: name,
        enabled: item['enabled'] != false,
        healthUrl: await store.read(_probeSecretKey(username, upstream, name)) ?? '',
      );
      if (selection.validationError == null) selections.add(selection);
    }
    return selections;
  } catch (_) {
    return null;
  }
}

Future<void> saveCorplinkNodeSelections(
  List<CorplinkNodeSelection> selections, {
  CorplinkNodeSecretStore? secrets,
}) async {
  final store = secrets ?? const _PlatformNodeSecrets();
  final previous = await loadCorplinkNodeSelections(secrets: store);
  final requestedNames = selections.map((item) => item.serverName).toSet();
  final retained = <CorplinkNodeSelection>[
    ...selections,
    for (final item in previous ?? const <CorplinkNodeSelection>[])
      if (!requestedNames.contains(item.serverName))
        CorplinkNodeSelection(
          serverName: item.serverName,
          enabled: false,
          healthUrl: item.healthUrl,
        ),
  ];
  final seen = <String>{};
  var enabledIntl = 0;
  for (final selection in retained) {
    final error = selection.validationError;
    if (error != null) throw ArgumentError.value(selection.serverName, 'selection', error);
    if (!seen.add(selection.serverName.toLowerCase())) {
      throw ArgumentError.value(selection.serverName, 'selection', '节点名称重复');
    }
    if (selection.enabled && isIntlCorplinkServerName(selection.serverName)) {
      enabledIntl++;
    }
  }
  if (enabledIntl > 1) {
    throw ArgumentError('同一 INTL 服务器的别名不能同时启用');
  }
  final prefs = await SharedPreferences.getInstance();
  final username = prefs.getString(corplinkSgUsernameKey) ?? '';
  final upstream = prefs.getString(corplinkSgServerKey) ?? '';
  for (final selection in retained) {
    await store.write(
      _probeSecretKey(username, upstream, selection.serverName),
      selection.healthUrl,
    );
  }
  await prefs.setString(_selectionPreferenceKey, jsonEncode([
    for (final selection in retained)
      {'serverName': selection.serverName, 'enabled': selection.enabled},
  ]));
}

List<String> parseCorplinkVPNNodeSummaries(List<dynamic> records) {
  final names = <String>[];
  final seen = <String>{};
  for (final record in records) {
    if (record is! Map || record['protocolMode'] != 1) continue;
    final name = record['name'];
    if (name is! String ||
        CorplinkNodeSelection(serverName: name).validationError != null ||
        !seen.add(name)) {
      continue;
    }
    names.add(name);
  }
  return names;
}
