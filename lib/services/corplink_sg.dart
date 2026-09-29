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
import 'package:bett_box/plugins/vpn.dart';

const corplinkSgEnabledKey = 'corplinkSg.enabled';
const corplinkSgRouteOpenAiKey = 'corplinkSg.routeOpenAi';
const corplinkSgUsernameKey = 'corplinkSg.username';
const corplinkSgServerKey = 'corplinkSg.server';
const corplinkSgPasswordSecureKey = 'corplinkSg.password';
const corplinkSgDeviceIdSecureKey = 'corplinkSg.deviceId';
const corplinkSgDeviceNameSecureKey = 'corplinkSg.deviceName';
const _secureStorage = FlutterSecureStorage();
final corplinkSgLastErrorCode = ValueNotifier<String?>(null);
final corplinkSgLastCoreErrorCode = ValueNotifier<String?>(null);

class CorplinkSgSettings {
  final bool enabled;
  final bool routeOpenAi;
  final String username;
  final String password;
  final String server;

  const CorplinkSgSettings({
    this.enabled = false,
    this.routeOpenAi = true,
    this.username = '',
    this.password = '',
    this.server = '',
  });

  bool get isConfigured =>
      username.trim().isNotEmpty &&
      password.isNotEmpty &&
      server.trim().isNotEmpty;

  String? get validationError {
    if (!enabled) return null;
    if (username.trim().isEmpty) return '请输入飞连用户名';
    if (password.isEmpty) return '请输入飞连密码';
    if (server.trim().isEmpty) return '请输入上游服务器地址';
    final uri = Uri.tryParse(server.trim());
    if (uri == null || uri.host.isEmpty) return '上游服务器地址无效';
    return null;
  }

  static Future<CorplinkSgSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final securePassword =
        await _secureStorage.read(key: corplinkSgPasswordSecureKey) ?? '';
    return CorplinkSgSettings(
      enabled: prefs.getBool(corplinkSgEnabledKey) ?? false,
      routeOpenAi: prefs.getBool(corplinkSgRouteOpenAiKey) ?? true,
      username: prefs.getString(corplinkSgUsernameKey) ?? '',
      password: securePassword,
      server: prefs.getString(corplinkSgServerKey) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(corplinkSgEnabledKey, enabled);
    await prefs.setBool(corplinkSgRouteOpenAiKey, routeOpenAi);
    await prefs.setString(corplinkSgUsernameKey, username);
    await _secureStorage.write(
      key: corplinkSgPasswordSecureKey,
      value: password,
    );
    await prefs.setString(corplinkSgServerKey, server);
  }

  Future<void> disable() => CorplinkSgSettings(
    routeOpenAi: routeOpenAi,
    username: username,
    password: password,
    server: server,
  ).save();
}

bool corplinkSgSettingsChanged(
  CorplinkSgSettings before,
  CorplinkSgSettings after,
) {
  return before.enabled != after.enabled ||
      before.routeOpenAi != after.routeOpenAi ||
      before.username != after.username ||
      before.password != after.password ||
      before.server != after.server;
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

Future<bool> ensureCorplinkAuthorization(
  CorplinkSgSettings settings, {
  bool force = false,
}) async {
  // A settings change must not inherit the result of a login started with
  // another account or server.
  final previous = _authorizationInFlight;
  if (previous != null) {
    try {
      await previous;
    } catch (_) {
      // A failed prior attempt must not prevent a new account or retry.
    }
  }
  final attempt = _ensureCorplinkAuthorization(settings, force: force);
  _authorizationInFlight = attempt;
  try {
    return await attempt;
  } finally {
    if (identical(_authorizationInFlight, attempt)) {
      _authorizationInFlight = null;
    }
  }
}

Future<bool> _ensureCorplinkAuthorization(
  CorplinkSgSettings settings, {
  bool force = false,
}) async {
  if (Platform.isAndroid) {
    return _ensureAndroidCorplinkAuthorization(settings, force: force);
  }
  final home = await corplinkSgHomePath();
  final configPath = joinPath(home, 'config.json');
  final existing = await loadCorplinkConfig();
  if (!force &&
      corplinkAuthMatchesSettings(existing, settings) &&
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

  Future<void> sanitizeConfig() async {
    final current = await loadCorplinkConfig();
    if (current == null) return;
    current.remove('password');
    await File(configPath).writeAsString(jsonEncode(current));
  }

  final executable = Platform.isWindows ? 'corplink-rs.exe' : 'corplink-rs';
  final bundled = joinPath(appPath.executableDirPath, executable);
  final command = File(bundled).existsSync() ? bundled : executable;
  // corplink-rs direct mode is a long-running tunnel process. Do not use
  // Process.run here: it waits for the daemon to exit and would prevent
  // Bettbox from ever reaching config injection. We only use it as the
  // bootstrap/login helper, then Mihomo-SG owns the actual tunnel.
  late final Process process;
  try {
    process = await Process.start(
      command,
      [configPath],
      mode: ProcessStartMode.detachedWithStdio,
    );
  } on ProcessException catch (e) {
    await sanitizeConfig();
    commonPrint.log('[CorpLinkSG] helper unavailable: ${e.message}');
    return false;
  } on Object catch (e) {
    await sanitizeConfig();
    commonPrint.log('[CorpLinkSG] helper start failed: $e');
    return false;
  }
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
    await sanitizeConfig();
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
  {bool force = false}
) async {
  // The Rust client is the reference implementation for Feilian. It keeps a
  // domain-aware CookieStore and performs the node-side cookie migration that
  // the legacy Dart login cannot reproduce reliably. Keep the Dart flow only
  // as a compatibility fallback for installations where the helper is absent.
  //
  // Only fall back when the helper could not be launched at all (null). When
  // the helper ran but reported failure (false), do NOT mask it with the
  // legacy Dart flow: for a pure-password Feilian account the legacy flow
  // can never complete a login (it requires a TOTP completion URL), so it
  // would only convert a real helper error into a misleading LOGIN_FAILED.
  final nativeResult = await _ensureAndroidCorplinkRsAuthorization(
    settings,
    force: force,
  );
  if (nativeResult == true) return true;
  if (nativeResult == null) {
    return _ensureAndroidCorplinkAuthorizationLegacy(settings);
  }
  return false;
}

/// Discard renewable CorpLink session material. A server-side auth rejection
/// also invalidates the device binding: the next login must advertise a new
/// Android device identity so one account can keep multiple installations
/// connected, matching the Feilian multi-device revision.
Future<void> invalidateCorplinkAuthorization() async {
  final home = await corplinkSgHomePath();
  for (final name in const [
    'config.json',
    'corplink_cookies.json',
    'bettbox_cookies.txt',
  ]) {
    final file = File(joinPath(home, name));
    if (file.existsSync()) await file.delete();
  }
  await _secureStorage.delete(key: corplinkSgDeviceIdSecureKey);
  await _secureStorage.delete(key: corplinkSgDeviceNameSecureKey);
  _androidAuthorizationSessionKey = null;
}

Future<bool?> _ensureAndroidCorplinkRsAuthorization(
  CorplinkSgSettings settings,
  {bool force = false}
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
      corplinkAuthMatchesSettings(current, settings) &&
      File(cookiePath).existsSync();
  if (hasPersistedAuthorization && !force) {
    // The core will reject an expired session and the next explicit retry can
    // re-enter the helper. Do not force a browser/Feilian login on every app
    // process restart when the persisted session is still usable.
    _androidAuthorizationSessionKey = sessionKey;
    return true;
  }
  final identity = await _loadOrCreateAndroidIdentity(current);
  // The helper reuses the stable device identity and writes the refreshed
  // CookieStore/config atomically.

  final keyPair = await X25519().newKeyPair();
  final publicKey = hasPersistedAuthorization
      ? current!['public_key'].toString()
      : base64Encode((await keyPair.extractPublicKey()).bytes);
  final privateKey = hasPersistedAuthorization
      ? current!['private_key'].toString()
      : base64Encode(await keyPair.extractPrivateKeyBytes());
  final request = jsonEncode(buildAndroidCorplinkMachineRequest(
    server: settings.server.trim().replaceFirst(RegExp(r'/$'), ''),
    username: settings.username,
    password: settings.password,
    deviceName: identity.$1,
    deviceId: identity.$2,
    publicKey: publicKey,
    privateKey: privateKey,
    authFile: configPath,
    cookieFile: cookiePath,
  ));

  Process process;
  try {
    process = await Process.start(helperPath, ['--machine']);
  } on ProcessException catch (e) {
    // Surface the exact failure so Android logcat shows whether the helper
    // is missing, not executable, or rejected by the platform. A silent
    // fallback to the legacy Dart flow would dead-end on pure-password
    // Feilian (it cannot complete a login without a TOTP completion URL).
    debugPrint(
      '[APP] CorpLink helper Process.start failed '
      'path=$helperPath '
      'nativeLibraryDir=$nativeLibraryDir '
      'exists=${File(helperPath).existsSync()} '
      'error=${e.message}',
    );
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
          debugPrint('[APP] CorpLink helper event=login_url');
          final url = Uri.tryParse(event['url']?.toString() ?? '');
          if (url != null) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          }
        } else if (event['event'] == 'success') {
          debugPrint('[APP] CorpLink helper event=success');
          corplinkSgLastErrorCode.value = null;
          succeeded = true;
        } else if (event['event'] == 'auth_required') {
          debugPrint('[APP] CorpLink helper event=auth_required');
        } else if (event['event'] == 'error') {
          corplinkSgLastErrorCode.value =
              event['code']?.toString() ?? 'LOGIN_FAILED';
          debugPrint(
            '[APP] CorpLink helper event=error '
            'code=${event['code'] ?? 'unknown'}',
          );
        } else if (event['event'] == 'refresh_started') {
          debugPrint('[APP] CorpLink helper event=refresh_started');
        }
      } on FormatException {
        // Helper diagnostics are deliberately ignored by the protocol parser.
      }
    }
  }();
  final stderrFuture = () async {
    await for (final line in process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      // The helper keeps stdout machine-readable. Surface its redacted
      // diagnostics in the Bettbox log so Android failures are actionable.
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        debugPrint('[APP] CorpLink helper stderr: $trimmed');
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
  await stderrFuture;
  debugPrint(
    '[APP] CorpLink helper exit=$exitCode succeeded=$succeeded '
    'config=${File(configPath).existsSync()} cookie=${File(cookiePath).existsSync()}',
  );
  if (exitCode != 0 || !succeeded) return false;

  final generated = await loadCorplinkConfig();
  if (generated == null) return false;
  final sanitized = Map<String, dynamic>.from(generated)..remove('password');
  await File(configPath).writeAsString(jsonEncode(sanitized), flush: true);
  final authorized = sanitized['private_key'] is String &&
      (sanitized['private_key'] as String).isNotEmpty &&
      File(cookiePath).existsSync();
  if (authorized) _androidAuthorizationSessionKey = sessionKey;
  return authorized;
}

Map<String, dynamic> buildAndroidCorplinkMachineRequest({
  required String server,
  required String username,
  required String password,
  required String deviceName,
  required String deviceId,
  required String publicKey,
  required String privateKey,
  required String authFile,
  required String cookieFile,
}) {
  return {
    'protocol_version': 1,
    'action': 'login',
    'server': server,
    'company_name': 'Bettbox',
    // The saved username/password use the Feilian password flow.
    'platform': 'feilian',
    'username': username,
    'password': password,
    'device_name': deviceName,
    'device_id': deviceId,
    'public_key': publicKey,
    'private_key': privateKey,
    'interface_name': 'bettboxsg',
    'auth_file': authFile,
    'cookie_file': cookieFile,
    'vpn_server_name': 'FZ-INT-Node',
    'vpn_select_strategy': 'latency',
  };
}

Future<bool> _ensureAndroidCorplinkAuthorizationLegacy(
  CorplinkSgSettings settings,
) async {
  final home = await corplinkSgHomePath();
  await Directory(home).create(recursive: true);
  final configPath = joinPath(home, 'config.json');
  final cookiePath = joinPath(home, 'bettbox_cookies.txt');
  final rustCookiePath = joinPath(home, 'corplink_cookies.json');
  final current = await loadCorplinkConfig();
  final identity = await _loadOrCreateAndroidIdentity(current);
  if (corplinkAuthMatchesSettings(current, settings) &&
      (File(cookiePath).existsSync() || File(rustCookiePath).existsSync())) {
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
    // This Android profile is explicitly the Feilian password flow. Do not
    // silently switch to LDAP merely because the server advertises LDAP as
    // another available method.
    const platform = 'feilian';
    final password = sha256.convert(utf8.encode(settings.password)).toString();
    final login = await dio.post('$base/api/login$suffix',
        data: {
          'password': password,
          'user_name': settings.username,
        },
        options: requestOptions());
    collect(login);
    var otpUrl = (login.data is Map ? (login.data['data']?['url'] ?? '') : '').toString();
    if (otpUrl.isEmpty) {
      // Feilian password login must establish the authenticated session and
      // return its completion URL. /api/v2/p/otp only provisions a TOTP seed;
      // treating that seed as a login result creates a config that later
      // fails with the misleading "Cookies are missing" response.
      if (platform == 'feilian') return false;
      final otp = await dio.post('$base/api/v2/p/otp$suffix',
          data: {}, options: requestOptions());
      collect(otp);
      otpUrl = (otp.data is Map ? (otp.data['data']?['url'] ?? '') : '').toString();
    }
    final code = Uri.tryParse(otpUrl)?.queryParameters['secret'] ?? '';
    if (code.isEmpty || cookies.isEmpty) return false;
    // Prefer the freshly authenticated plain cookie over a stale CookieStore
    // left by an earlier Feishu/helper attempt. The core will use this file
    // for the password-login path on Android.
    final staleRustCookie = File(rustCookiePath);
    if (staleRustCookie.existsSync()) await staleRustCookie.delete();
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

Future<void> applyCorplinkSgNode(
  Map<String, dynamic> rawConfig, {
  bool suppressNode = false,
}) async {
  final settings = await CorplinkSgSettings.load();
  if (!settings.enabled) return;

  // The downloaded profile is read afresh for every apply. This overlay is
  // deliberately repeatable because scripts may replace the group list.
  final stored = await loadCorplinkConfig();
  final auth = corplinkAuthMatchesSettings(stored, settings) ? stored : null;
  final home = await corplinkSgHomePath();
  final interfaceName = auth?['interface_name']?.toString() ?? 'bettboxsg';
  final rustCookiePath = joinPath(home, 'corplink_cookies.json');
  final legacyCookiePath = joinPath(home, 'bettbox_cookies.txt');
  final cookiePath = Platform.isAndroid
      ? (File(rustCookiePath).existsSync()
          ? rustCookiePath
          : legacyCookiePath)
      : joinPath(home, '${interfaceName}_cookies.json');
  String? controlIP;
  if (Platform.isAndroid && !suppressNode && auth != null) {
    final host = Uri.tryParse(settings.server.trim())?.host;
    if (host != null && host.isNotEmpty && InternetAddress.tryParse(host) == null) {
      try {
        final physicalAddresses = await Vpn()
            .resolveUnderlyingHost(host)
            .timeout(const Duration(seconds: 4));
        controlIP = selectCorplinkPhysicalIP(physicalAddresses);
      } catch (_) {
        // The core retains the last successfully connected management IP.
        // A temporary physical DNS outage must not discard the whole profile.
      }
    }
  }
  mergeCorplinkSgOverlay(
    rawConfig,
    settings: settings,
    auth: File(cookiePath).existsSync() ? auth : null,
    cookiePath: cookiePath,
    controlIP: controlIP,
    suppressNode: suppressNode,
  );
}

String? selectCorplinkPhysicalIP(Iterable<String> addresses) {
  String? ipv6;
  for (final text in addresses) {
    final address = InternetAddress.tryParse(text);
    if (address == null) continue;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 &&
        bytes.length == 4 &&
        bytes[0] == 198 &&
        (bytes[1] == 18 || bytes[1] == 19)) {
      continue;
    }
    if (address.type == InternetAddressType.IPv4) return address.address;
    ipv6 ??= address.address;
  }
  return ipv6;
}

/// A previous failed authorization can leave REJECT stored as the selected
/// SG group member. Once the authorized group is rebuilt, REJECT is no longer
/// a member; showing that stale value misrepresents the working core route.
bool shouldReplaceStaleCorplinkSelection(
  String? savedSelection,
  Iterable<String> currentMembers,
) {
  return savedSelection != null &&
      savedSelection.isNotEmpty &&
      !currentMembers.contains(savedSelection);
}

bool corplinkAuthMatchesSettings(
  Map<String, dynamic>? auth,
  CorplinkSgSettings settings,
) {
  if (auth == null) return false;
  final server = settings.server.trim().replaceFirst(RegExp(r'/$'), '');
  return auth['username']?.toString() == settings.username.trim() &&
      auth['server']?.toString().replaceFirst(RegExp(r'/$'), '') == server &&
      (auth['private_key']?.toString().isNotEmpty ?? false) &&
      (auth['public_key']?.toString().isNotEmpty ?? false);
}

void mergeCorplinkSgOverlay(
  Map<String, dynamic> rawConfig, {
  required CorplinkSgSettings settings,
  Map<String, dynamic>? auth,
  String? cookiePath,
  String? controlIP,
  bool suppressNode = false,
}) {
  if (!settings.enabled) return;
  const nodeName = 'SG-Node';
  const groupName = 'SG-OpenAI';
  final authorized = !suppressNode &&
      settings.isConfigured &&
      corplinkAuthMatchesSettings(auth, settings) &&
      cookiePath != null &&
      cookiePath.isNotEmpty;

  final proxies = List<dynamic>.from(rawConfig['proxies'] as List? ?? const []);
  proxies.removeWhere((item) => item is Map && item['name'] == nodeName);
  if (authorized) {
    final apiServer = settings.server.trim();
    final privateKey = auth!['private_key'].toString();
    final publicKey = auth['public_key'].toString();
    proxies.add({
      'name': nodeName,
      'type': 'wireguard',
      'ip': '0.0.0.0',
      'private-key': privateKey,
      'server': Uri.parse(apiServer).host,
      'port': 34080,
      'public-key': publicKey,
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
        'corplink-code': auth['code']?.toString() ?? '',
        'corplink-cookie-file': cookiePath,
        'corplink-device-id': auth['device_id']?.toString() ?? '',
        'corplink-device-name': auth['device_name']?.toString() ?? nodeName,
        'corplink-vpn-server-name': 'FZ-INT-Node',
        'corplink-public-key': publicKey,
        'corplink-refresh-threshold-hours': 48,
        'corplink-refresh-hour': 3,
      },
    });
  }
  rawConfig['proxies'] = proxies;

  final groups = List<dynamic>.from(
    rawConfig['proxy-groups'] as List? ?? const [],
  );
  groups.removeWhere((group) => group is Map && group['name'] == groupName);
  final openAiGroup = RegExp(r'openai|chatgpt', caseSensitive: false);
  String? primarySubscriptionGroup;
  for (final group in groups) {
    if (group is! Map) continue;
    final name = group['name']?.toString() ?? '';
    final kind = group['type']?.toString().toLowerCase();
    if (name != 'GLOBAL' &&
        !openAiGroup.hasMatch(name) &&
        primarySubscriptionGroup == null &&
        {'select', 'url-test', 'fallback', 'load-balance'}.contains(kind)) {
      primarySubscriptionGroup = name;
    }
    if (group['proxies'] is! List) continue;
    final targeted = name == 'GLOBAL' || openAiGroup.hasMatch(name);
    if (authorized && !targeted) continue;
    final members = List<dynamic>.from(group['proxies'] as List);
    members.remove(nodeName);
    if (members.isEmpty) members.add('REJECT');
    group['proxies'] = authorized && settings.routeOpenAi && targeted
        ? <dynamic>[nodeName, ...members]
        : members;
  }

  groups.add({
    'name': groupName,
    'type': 'select',
    'proxies': authorized
        ? <String>[nodeName, if (primarySubscriptionGroup != null) primarySubscriptionGroup]
        : <String>['REJECT'],
  });
  rawConfig['proxy-groups'] = groups;

  final rulesKey = rawConfig['rules'] is List ? 'rules' : 'rule';
  final rules = List<dynamic>.from(rawConfig[rulesKey] as List? ?? const []);
  // Re-applying the overlay must only replace rules generated by this app.
  // A script may add its own RULE-SET targeting SG-OpenAI; deleting every
  // rule with that target silently disables the user's provider routing.
  rules.removeWhere(
    (rule) => rule is String && corplinkOpenAiRules.contains(rule),
  );
  rawConfig[rulesKey] = settings.routeOpenAi
      ? <dynamic>[...corplinkOpenAiRules, ...rules]
      : rules;
  rawConfig.remove(rulesKey == 'rules' ? 'rule' : 'rules');
}

const corplinkOpenAiRules = <String>[
  'DOMAIN-SUFFIX,chatgpt.com,SG-OpenAI',
  'DOMAIN-SUFFIX,openai.com,SG-OpenAI',
  'DOMAIN-SUFFIX,chat.openai.com,SG-OpenAI',
  'DOMAIN-SUFFIX,api.openai.com,SG-OpenAI',
  'DOMAIN-SUFFIX,platform.openai.com,SG-OpenAI',
  'DOMAIN-SUFFIX,auth0.openai.com,SG-OpenAI',
  'DOMAIN-SUFFIX,cdn.openai.com,SG-OpenAI',
  'DOMAIN-SUFFIX,openaiusercontent.com,SG-OpenAI',
  'DOMAIN-SUFFIX,oaistatic.com,SG-OpenAI',
  'DOMAIN-SUFFIX,oaiusercontent.com,SG-OpenAI',
  'DOMAIN-KEYWORD,openai,SG-OpenAI',
  'DOMAIN-KEYWORD,chatgpt,SG-OpenAI',
];
