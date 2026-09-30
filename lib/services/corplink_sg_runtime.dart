import 'dart:async';
import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/system.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:bett_box/state.dart';

Future<SgCoreStatus> readCorplinkSgStatus() async =>
    SgCoreStatus.fromJson(await clashCore.getCorplinkSgStatus());

Future<List<SgCoreStatus>> readCorplinkNodeStatuses() async {
  final records = await clashCore.getCorplinkNodeStatuses();
  return [
    for (final record in records)
      if (record is Map) SgCoreStatus.fromJson(record),
  ];
}

Future<SgCoreStatus> readCorplinkNodeStatus(String serverName) async {
  final statuses = await readCorplinkNodeStatuses();
  for (final status in statuses) {
    if (status.serverName == serverName) return status;
  }
  return SgCoreStatus(
    serverName: serverName,
    present: false,
    initialized: false,
    ready: false,
    rebuildRequired: false,
    closed: false,
    tunnelIp: '',
    endpoint: '',
  );
}

Future<bool> probeCorplinkNodeHttps(String serverName, String url) async {
  try {
    final delay = await clashCore.getDelay(url, '$serverName-WG');
    return delay.value != null && delay.value! > 0;
  } catch (_) {
    return false;
  }
}

Future<bool> observeCorplinkNodeProbe(
  String serverName,
  String url, {
  required Future<bool> Function(String serverName, String url) probe,
  void Function(bool success)? onProbe,
}) async {
  final success = await probe(serverName, url);
  onProbe?.call(success);
  return success;
}

class CorplinkNodeProbeObservation {
  const CorplinkNodeProbeObservation({
    required this.success,
    required this.checkedAt,
  });

  final bool success;
  final DateTime checkedAt;
}

final _corplinkVpnStartGate = CorplinkVpnStartGate();

Future<void> ensureCorplinkVpnReady() async {
  final needsNativeTun = system.isAndroid && globalState.config.vpnProps.enable;
  final ready = await _corplinkVpnStartGate.ensureReady(
    waitForNative: needsNativeTun,
    isNativeReady: () async => await clashLib?.getAndroidVpnReady() == true,
    requestStart: () async {
      // Native readiness, not an optimistic UI timestamp, governs Android
      // retries after a cancelled permission prompt or a failed constructor.
      if (needsNativeTun || !globalState.isStart) {
        await globalState.appController.updateStatus(true);
      }
    },
    settle: () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  if (!ready) throw StateError('ANDROID_VPN_START_TIMEOUT');
  if (system.isAndroid) {
    try {
      final nativeTime = await clashLib?.getRunTime().timeout(const Duration(seconds: 1));
      if (nativeTime != null) globalState.startTime = nativeTime;
    } on TimeoutException {
      // The readiness decision already succeeded; a delayed clock read must
      // not hold the user action for the IPC's much longer default timeout.
    }
  }
}

Future<SgCoreStatus> refreshCorplinkNodeStatus(
  String serverName, {
  String healthUrl = '',
  void Function(bool success)? onProbe,
}) async {
  await ensureCorplinkVpnReady();
  return recoverCorplinkNodeStatus(
    serverName: serverName,
    readStatus: () => readCorplinkNodeStatus(serverName),
    ensureHandshake: clashCore.ensureCorplinkNode,
    reconnect: clashCore.reconnectCorplinkNode,
    rebuild: clashCore.rebuildCorplinkNode,
    probeUrl: healthUrl,
    probe: (name, url) => observeCorplinkNodeProbe(
      name,
      url,
      probe: probeCorplinkNodeHttps,
      onProbe: onProbe,
    ),
  );
}

/// After Android moves to a new physical network, probe each managed
/// handshake and retry only the outbounds that did not recover. This does
/// not reload the Profile or disturb an already-ready sibling.
Future<Set<String>> restoreCorplinkNodesAfterNetworkChange(
  Iterable<String> serverNames, {
  required Future<bool> Function(String) ensureHandshake,
  required Future<SgCoreStatus> Function(String) readStatus,
  required Future<bool> Function(String) reconnect,
  required Future<bool> Function(String) rebuild,
}) async {
  final unready = <String>{};
  await Future.wait([
    for (final name in serverNames.toSet())
      () async {
        try {
          await ensureHandshake(name);
          var status = await readStatus(name);
          if (status.phase != SgConnectionPhase.ready) {
            final accepted = status.rebuildRequired
                ? await rebuild(name)
                : await reconnect(name);
            if (accepted) await ensureHandshake(name);
            status = await readStatus(name);
          }
          if (status.phase != SgConnectionPhase.ready) unready.add(name);
        } catch (_) {
          unready.add(name);
        }
      }(),
  ]);
  return unready;
}

Future<List<String>> discoverCorplinkVpnNodeNames(CorplinkSgSettings settings) async {
  if (!settings.isConfigured || !(await ensureCorplinkAuthorization(settings))) {
    throw StateError('CORPLINK_AUTH_REQUIRED');
  }
  final auth = await loadCorplinkConfig();
  if (!corplinkAuthMatchesSettings(auth, settings)) {
    throw StateError('CORPLINK_AUTH_REQUIRED');
  }
  final home = await corplinkSgHomePath();
  final rustCookies = joinPath(home, 'corplink_cookies.json');
  final cookiePath = File(rustCookies).existsSync()
      ? rustCookies
      : joinPath(home, 'bettbox_cookies.txt');
  if (!File(cookiePath).existsSync()) {
    throw StateError('CORPLINK_COOKIE_MISSING');
  }
  final host = Uri.parse(settings.server.trim()).host;
  String? controlIP;
  if (InternetAddress.tryParse(host) == null) {
    try {
      final addresses = await Vpn()
          .resolveUnderlyingHost(host)
          .timeout(const Duration(seconds: 4));
      controlIP = selectCorplinkPhysicalIP(addresses);
    } catch (_) {
      // The core can still use its last protected control-plane address.
    }
  }
  final records = await clashCore.listCorplinkVpnNodes({
    'apiServer': settings.server.trim(),
    'cookieFile': cookiePath,
    'deviceId': auth!['device_id']?.toString() ?? '',
    'deviceName': auth['device_name']?.toString() ?? '',
    if (controlIP != null) 'controlIP': controlIP,
  });
  return parseCorplinkVPNNodeSummaries(records);
}

Future<bool> probeCorplinkSgChatGpt() async {
  try {
    final delay = await clashCore.getDelay(
      'https://chatgpt.com/robots.txt', 'SG-Node');
    return delay.value != null && delay.value! > 0;
  } catch (_) {
    return false;
  }
}

Future<bool> probeCorplinkSgFallback() async {
  try {
    final delay = await clashCore.getDelay(
      'https://www.apple.com/library/test/success.html', 'SG-Node');
    return delay.value != null && delay.value! > 0;
  } catch (_) {
    return false;
  }
}

Future<SgCoreStatus> refreshCorplinkSgStatus({
  Future<bool> Function()? probe,
  Future<bool> Function()? fallbackProbe,
}) =>
    recoverSgStatus(
      ensureVpn: ensureCorplinkVpnReady,
      readStatus: readCorplinkSgStatus,
      probe: probe ?? probeCorplinkSgChatGpt,
      fallbackProbe: fallbackProbe ?? probeCorplinkSgFallback,
      reconnect: clashCore.reconnectCorplinkTunnel,
      rebuild: () => globalState.appController.applyProfile(silence: true),
      settle: () => Future<void>.delayed(const Duration(seconds: 2)),
    );
