import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bett_box/plugins/app.dart';

const corplinkSgEnabledKey = 'corplinkSg.enabled';
const corplinkSgUsernameKey = 'corplinkSg.username';
const corplinkSgServerKey = 'corplinkSg.server';
const corplinkSgPasswordSecureKey = 'corplinkSg.password';
const corplinkSgDeviceIdSecureKey = 'corplinkSg.deviceId';
const corplinkSgDeviceNameSecureKey = 'corplinkSg.deviceName';
const _secureStorage = FlutterSecureStorage();

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
    final securePassword =
        await _secureStorage.read(key: corplinkSgPasswordSecureKey) ?? '';
    return CorplinkSgSettings(
      enabled: prefs.getBool(corplinkSgEnabledKey) ?? false,
      username: prefs.getString(corplinkSgUsernameKey) ?? '',
      password: securePassword,
      server: prefs.getString(corplinkSgServerKey) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(corplinkSgEnabledKey, enabled);
    await prefs.setString(corplinkSgUsernameKey, username);
    await _secureStorage.write(
      key: corplinkSgPasswordSecureKey,
      value: password,
    );
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

Future<bool>? _authorizationInFlight;
String? _androidAuthorizationSessionKey;

Future<(String, String)> _loadOrCreateAndroidIdentity(
  Map<String, dynamic>? current,
) async {
  final storedName = await _secureStorage.read(key: corplinkSgDeviceNameSecureKey);
  final storedId = await _secureStorage.read(key: corplinkSgDeviceIdSecureKey);
  if (storedName != null && storedName.isNotEmpty &&
      storedId != null && storedId.isNotEmpty) {
    return (storedName, storedId);
  }

  final currentName = current?['device_name']?.toString() ?? '';
  final currentId = current?['device_id']?.toString() ?? '';
  if (currentName.isNotEmpty && currentId.isNotEmpty) {
    await _secureStorage.write(key: corplinkSgDeviceNameSecureKey, value: currentName);
    await _secureStorage.write(key: corplinkSgDeviceIdSecureKey, value: currentId);
    return (currentName, currentId);
  }

  // Android's hostname is commonly "localhost" and is not an installation
  // identity. Generate a stable random identity once per Bettbox install.
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final suffix = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  final name = 'SG-Node-Android-${suffix.substring(0, 12)}';
  final id = md5.convert(utf8.encode(name)).toString();
  await _secureStorage.write(key: corplinkSgDeviceNameSecureKey, value: name);
  await _secureStorage.write(key: corplinkSgDeviceIdSecureKey, value: id);
  return (name, id);
}

Future<bool> ensureCorplinkAuthorization(CorplinkSgSettings settings) {
  return _authorizationInFlight ??= _ensureCorplinkAuthorization(
    settings,
  ).whenComplete(() => _authorizationInFlight = null);
}

Future<bool> _ensureCorplinkAuthorization(CorplinkSgSettings settings) async {
  if (Platform.isAndroid) {
    return _ensureAndroidCorplinkAuthorization(settings);
  }
  final home = await corplinkSgHomePath();
  final configPath = joinPath(home, 'config.json');
  final existing = await loadCorplinkConfig();
  if (existing?['private_key'] is String &&
      (existing?['private_key'] as String).isNotEmpty &&
      existing?['code'] is String &&
      (existing?['code'] as String).isNotEmpty) {
    return true;
  }

  await Directory(home).create(recursive: true);
  final config = {
    'username': settings.username,
    'password': settings.password,
    'server': settings.server,
    'platform': 'ldap',
    'device_name': 'SG-Node-${Platform.localHostname}',
    'device_id': null,
    'public_key': null,
    'private_key': null,
    'interface_name': 'bettboxsg',
    'vpn_select_strategy': 'latency',
    'use_vpn_dns': false,
  };
  await File(configPath).writeAsString(jsonEncode(config));

  final executable = Platform.isWindows ? 'corplink-rs.exe' : 'corplink-rs';
  final bundled = joinPath(appPath.executableDirPath, executable);
  final command = File(bundled).existsSync() ? bundled : executable;
  // corplink-rs direct mode is a long-running tunnel process. Do not use
  // Process.run here: it waits for the daemon to exit and would prevent
  // Bettbox from ever reaching config injection. We only use it as the
  // bootstrap/login helper, then Mihomo-SG owns the actual tunnel.
  final process = await Process.start(
    command,
    [configPath],
    mode: ProcessStartMode.detachedWithStdio,
  );
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  Map<String, dynamic>? updated;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    updated = await loadCorplinkConfig();
    final hasPrivateKey = updated?['private_key'] is String &&
        (updated?['private_key'] as String).isNotEmpty;
    final hasCode = updated?['code'] is String &&
        (updated?['code'] as String).isNotEmpty;
    if (hasPrivateKey && hasCode) break;
  }
  final authorized = updated?['private_key'] is String &&
      (updated?['private_key'] as String).isNotEmpty &&
      updated?['code'] is String &&
      (updated?['code'] as String).isNotEmpty;
  if (!authorized) {
    process.kill();
    return false;
  }
  process.kill();
  if (authorized) {
    // The generated config is retained for non-secret authorization material,
    // but the password is not left on disk after the bootstrap process.
    final sanitized = Map<String, dynamic>.from(updated!);
    sanitized.remove('password');
    await File(configPath).writeAsString(jsonEncode(sanitized));
  }
  return authorized;
}

Future<bool> _ensureAndroidCorplinkAuthorization(
  CorplinkSgSettings settings,
) async {
  final helperResult = await _ensureAndroidCorplinkRsAuthorization(settings);
  if (helperResult != null) return helperResult;
  return _ensureAndroidCorplinkAuthorizationLegacy(settings);
}

Future<bool?> _ensureAndroidCorplinkRsAuthorization(
  CorplinkSgSettings settings,
) async {
  final home = await corplinkSgHomePath();
  await Directory(home).create(recursive: true);
  // Android SELinux does not allow an app to execute an ELF copied into its
  // ordinary files directory. The CI build packages this helper as a native
  // library, whose extracted directory is executable by the app process.
  final nativeLibraryDir = Platform.isAndroid
      ? await app.getNativeLibraryDir()
      : null;
  final helperPath = nativeLibraryDir == null
      ? joinPath(home, 'corplink-rs-login')
      : joinPath(nativeLibraryDir, 'libcorplink-rs-login.so');
  try {
    if (!File(helperPath).existsSync() && nativeLibraryDir == null) {
      final bytes = await rootBundle.load(
        'assets/bin/android-arm64-v8a/corplink-rs-login',
      );
      await File(helperPath).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      await Process.run('/system/bin/chmod', ['700', helperPath]);
    }
  } on FlutterError {
    return null;
  } on FileSystemException {
    return null;
  }

  final configPath = joinPath(home, 'config.json');
  final cookiePath = joinPath(home, 'corplink_cookies.json');
  final current = await loadCorplinkConfig();
  final sessionKey = '${settings.username}\u0000${settings.server}';
  final hasPersistedAuthorization =
      current?['private_key'] is String &&
      (current?['private_key'] as String).isNotEmpty &&
      current?['public_key'] is String &&
      (current?['public_key'] as String).isNotEmpty &&
      current?['code'] is String &&
      (current?['code'] as String).isNotEmpty &&
      File(cookiePath).existsSync();
  if (hasPersistedAuthorization) {
    // The core will reject an expired session and the next explicit retry can
    // re-enter the helper. Do not force a browser/Feilian login on every app
    // process restart when the persisted session is still usable.
    _androidAuthorizationSessionKey = sessionKey;
    return true;
  }
  final identity = await _loadOrCreateAndroidIdentity(current);
  if (_androidAuthorizationSessionKey == sessionKey) return true;

  // The helper reuses the stable device identity and writes the refreshed
  // CookieStore/config atomically.

  final keyPair = await X25519().newKeyPair();
  final publicKey = base64Encode((await keyPair.extractPublicKey()).bytes);
  final privateKey = base64Encode(await keyPair.extractPrivateKeyBytes());
  final request = jsonEncode({
    'protocol_version': 1,
    'action': 'login',
    'server': settings.server.trim().replaceFirst(RegExp(r'/$'), ''),
    'company_name': 'Bettbox',
    // The Feilian deployment exposes the Feishu/Lark third-party flow to the
    // machine protocol. The helper rejects requests without this field.
    'platform': 'lark',
    'username': settings.username,
    'password': settings.password,
    'device_name': identity.$1,
    'device_id': identity.$2,
    'public_key': publicKey,
    'private_key': privateKey,
    'interface_name': 'bettboxsg',
    'auth_file': configPath,
    'cookie_file': cookiePath,
    'vpn_server_name': 'FUZHOU_INTL_node',
    'vpn_select_strategy': 'latency',
  });

  Process process;
  try {
    process = await Process.start(helperPath, ['--machine']);
  } on ProcessException {
    return null;
  }
  var succeeded = false;
  final stdoutFuture = () async {
    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      try {
        final event = jsonDecode(line);
        if (event is! Map) continue;
        if (event['event'] == 'login_url') {
          final url = Uri.tryParse(event['url']?.toString() ?? '');
          if (url != null) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          }
        } else if (event['event'] == 'success') {
          succeeded = true;
        }
      } on FormatException {
        // Helper diagnostics are deliberately ignored by the protocol parser.
      }
    }
  }();
  process.stdin.write(request);
  await process.stdin.close();
  final exitCode = await process.exitCode.timeout(
    const Duration(minutes: 6),
    onTimeout: () {
      process.kill(ProcessSignal.sigterm);
      return -1;
    },
  );
  await stdoutFuture;
  if (exitCode != 0 || !succeeded) return false;

  final generated = await loadCorplinkConfig();
  if (generated == null) return false;
  final sanitized = Map<String, dynamic>.from(generated)..remove('password');
  await File(configPath).writeAsString(jsonEncode(sanitized), flush: true);
  final authorized = sanitized['private_key'] is String &&
      (sanitized['private_key'] as String).isNotEmpty &&
      sanitized['code'] is String &&
      (sanitized['code'] as String).isNotEmpty &&
      File(cookiePath).existsSync();
  if (authorized) _androidAuthorizationSessionKey = sessionKey;
  return authorized;
}

Future<bool> _ensureAndroidCorplinkAuthorizationLegacy(
  CorplinkSgSettings settings,
) async {
  final home = await corplinkSgHomePath();
  await Directory(home).create(recursive: true);
  final configPath = joinPath(home, 'config.json');
  final current = await loadCorplinkConfig();
  final identity = await _loadOrCreateAndroidIdentity(current);
  if (current?['private_key'] is String &&
      (current?['private_key'] as String).isNotEmpty &&
      current?['public_key'] is String &&
      (current?['public_key'] as String).isNotEmpty &&
      current?['code'] is String &&
      (current?['code'] as String).isNotEmpty) {
    return true;
  }
  final base = settings.server.trim().replaceFirst(RegExp(r'/$'), '');
  final deviceName = identity.$1;
  final deviceId = identity.$2;
  final keyPair = await X25519().newKeyPair();
  final publicKey = base64Encode((await keyPair.extractPublicKey()).bytes);
  final privateKey = base64Encode(await keyPair.extractPrivateKeyBytes());
  final dio = Dio(BaseOptions(
    validateStatus: (status) => status != null && status < 500,
    headers: {'User-Agent': 'okhttp/3.14.9', 'Content-Type': 'application/json'},
  ));
  final cookies = <String, String>{};
  void collect(Response<dynamic> response) {
    for (final raw in response.headers['set-cookie'] ?? const <String>[]) {
      final part = raw.split(';').first;
      final pair = part.split('=');
      if (pair.length >= 2) cookies[pair.first] = pair.sublist(1).join('=');
    }
  }
  Options requestOptions() => Options(headers: {
        'Cookie': [
          ...cookies.entries.map((e) => '${e.key}=${e.value}'),
          'device_id=$deviceId',
          'device_name=$deviceName',
        ].join('; '),
        if (cookies['csrf-token'] != null) 'csrf-token': cookies['csrf-token'],
      });
  try {
    final suffix = '?os=Android&os_version=2';
    final methods = await dio.get('$base/api/login/setting$suffix', options: requestOptions());
    collect(methods);
    final methodData = methods.data is Map ? methods.data['data'] : null;
    final loginOrders = methodData is Map && methodData['login_orders'] is List
        ? (methodData['login_orders'] as List)
            .map((e) => e.toString().toLowerCase())
            .toList()
        : const <String>[];
    final lookup = await dio.post('$base/api/lookup$suffix',
        data: {'forget_password': false, 'user_name': settings.username},
        options: requestOptions());
    collect(lookup);
    final platform = loginOrders.contains('ldap') ? 'ldap' : 'feilian';
    final password = platform == 'ldap'
        ? settings.password
        : sha256.convert(utf8.encode(settings.password)).toString();
    final login = await dio.post('$base/api/login$suffix',
        data: {
          'password': password,
          'user_name': settings.username,
          if (platform == 'ldap') 'platform': 'ldap',
        },
        options: requestOptions());
    collect(login);
    var otpUrl = (login.data is Map ? (login.data['data']?['url'] ?? '') : '').toString();
    if (otpUrl.isEmpty) {
      final otp = await dio.post('$base/api/v2/p/otp$suffix',
          data: {}, options: requestOptions());
      collect(otp);
      otpUrl = (otp.data is Map ? (otp.data['data']?['url'] ?? '') : '').toString();
    }
    final code = Uri.tryParse(otpUrl)?.queryParameters['secret'] ?? '';
    if (code.isEmpty || cookies.isEmpty) return false;
    final cookiePath = joinPath(home, 'bettbox_cookies.txt');
    await File(cookiePath).writeAsString(
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
    await File(configPath).writeAsString(jsonEncode({
      'username': settings.username,
      'server': base,
      'platform': platform,
      'device_name': deviceName,
      'device_id': deviceId,
      'public_key': publicKey,
      'private_key': privateKey,
      'code': code,
      'interface_name': 'bettboxsg',
    }));
    return true;
  } on DioException {
    return false;
  }
}

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

  if (!await ensureCorplinkAuthorization(settings)) return;
  final auth = await loadCorplinkConfig();
  if (auth == null) return;
  final proxies =
      (rawConfig['proxies'] as List?)?.cast<dynamic>() ?? <dynamic>[];
  const name = 'SG-Node-Linux';
  proxies.removeWhere((item) => item is Map && item['name'] == name);
  final home = await corplinkSgHomePath();
  final interfaceName = auth['interface_name']?.toString() ?? 'wgdevtest22';
  // The machine-mode Rust helper writes CookieStore JSON. Keep the old plain
  // Android cookie file as a fallback for upgrades, but never let a stale
  // legacy file shadow a freshly refreshed session.
  final rustCookiePath = joinPath(home, 'corplink_cookies.json');
  final legacyAndroidCookiePath = joinPath(home, 'bettbox_cookies.txt');
  final cookiePath = Platform.isAndroid
      ? (File(rustCookiePath).existsSync()
          ? rustCookiePath
          : legacyAndroidCookiePath)
      : joinPath(home, '${interfaceName}_cookies.json');
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
      // FUZHOU_INTL_node is the TCP/SG node used by the current Feilian
      // deployment. Mihomo resolves its actual endpoint through /api/vpn/list.
      'corplink-vpn-server-name': 'FUZHOU_INTL_node',
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
    final groupName = group['name']?.toString().toLowerCase() ?? '';
    final isOpenAiGroup = groupName.contains('openai') || groupName.contains('chatgpt');
    if (list is List && isOpenAiGroup) {
      if (!list.contains(name)) list.insert(0, name);
    }
  }
  rawConfig['proxy-groups'] = groups;
}
