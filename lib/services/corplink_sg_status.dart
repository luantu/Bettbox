enum SgConnectionPhase { missing, waitingForTraffic, connecting, ready, needsRebuild }

enum SgStatusRecovery { none, probe, reconnect, rebuild }

/// Read-only core telemetry. This model intentionally has no auth material.
class SgCoreStatus {
  const SgCoreStatus({
    this.serverName = '',
    required this.present,
    required this.initialized,
    required this.ready,
    required this.rebuildRequired,
    required this.closed,
    required this.tunnelIp,
    required this.endpoint,
    this.routesPresent = false,
    this.routeSplit = const [],
    this.routeFull = const [],
    this.routeInvalid = 0,
  });

  final String serverName;
  final bool present;
  final bool initialized;
  final bool ready;
  final bool rebuildRequired;
  final bool closed;
  final String tunnelIp;
  final String endpoint;
  final bool routesPresent;
  final List<String> routeSplit;
  final List<String> routeFull;
  final int routeInvalid;

  static List<String> _routeList(dynamic value) => List<String>.unmodifiable(
        value is List ? value.whereType<String>() : const <String>[],
      );

  factory SgCoreStatus.fromJson(Map<dynamic, dynamic> json) => SgCoreStatus(
        serverName: json['serverName'] as String? ?? '',
        present: json['present'] == true,
        initialized: json['initialized'] == true,
        ready: json['ready'] == true,
        rebuildRequired: json['rebuildRequired'] == true,
        closed: json['closed'] == true,
        tunnelIp: json['tunnelIp'] as String? ?? '',
        endpoint: json['endpoint'] as String? ?? '',
        routesPresent: json['routesPresent'] == true,
        routeSplit: _routeList(json['routeSplit']),
        routeFull: _routeList(json['routeFull']),
        routeInvalid: json['routeInvalid'] is num
            ? (json['routeInvalid'] as num).toInt()
            : 0,
      );

  SgConnectionPhase get phase {
    if (!present || closed) return SgConnectionPhase.missing;
    if (rebuildRequired) return SgConnectionPhase.needsRebuild;
    if (!initialized) return SgConnectionPhase.waitingForTraffic;
    return ready ? SgConnectionPhase.ready : SgConnectionPhase.connecting;
  }

  SgStatusRecovery get recovery => switch (phase) {
        SgConnectionPhase.ready => SgStatusRecovery.none,
        SgConnectionPhase.waitingForTraffic => SgStatusRecovery.probe,
        SgConnectionPhase.connecting => SgStatusRecovery.reconnect,
        SgConnectionPhase.missing || SgConnectionPhase.needsRebuild =>
          SgStatusRecovery.rebuild,
      };
}

class SgNodeAggregate {
  const SgNodeAggregate({required this.ready, required this.total});

  final int ready;
  final int total;

  String get label => total == 0 ? '未选择节点' : '$ready/$total 已连接';
}

SgNodeAggregate summarizeCorplinkNodes(
  Iterable<SgCoreStatus> statuses,
  Iterable<String> enabledServerNames,
) {
  final names = enabledServerNames.toSet();
  final ready = statuses.where((status) =>
      names.contains(status.serverName) && status.phase == SgConnectionPhase.ready).length;
  return SgNodeAggregate(ready: ready, total: names.length);
}

/// Manual refresh addresses only one named outbound. A custom HTTPS probe is
/// diagnostic; a blocked website never overrides a ready WireGuard handshake.
Future<SgCoreStatus> recoverCorplinkNodeStatus({
  required String serverName,
  required Future<SgCoreStatus> Function() readStatus,
  required Future<bool> Function(String) ensureHandshake,
  required Future<bool> Function(String) reconnect,
  required Future<bool> Function(String) rebuild,
  String probeUrl = '',
  Future<bool> Function(String serverName, String url)? probe,
}) async {
  var status = await readStatus();
  switch (status.phase) {
    case SgConnectionPhase.needsRebuild:
      if (await rebuild(serverName)) await ensureHandshake(serverName);
      break;
    case SgConnectionPhase.waitingForTraffic:
      await ensureHandshake(serverName);
      break;
    case SgConnectionPhase.connecting:
      if (await reconnect(serverName)) await ensureHandshake(serverName);
      break;
    case SgConnectionPhase.missing:
    case SgConnectionPhase.ready:
      break;
  }
  status = await readStatus();
  if (status.phase == SgConnectionPhase.ready &&
      probeUrl.isNotEmpty && probe != null) {
    await probe(serverName, probeUrl);
  }
  return status;
}

/// Bring up the lazy tunnel after Android VpnService starts. A failed website
/// request alone is not evidence that a completed WireGuard handshake failed.
Future<bool> recoverInitialSgConnection({
  required Future<bool> Function() probe,
  required Future<SgCoreStatus> Function() readStatus,
  required Future<bool> Function() reconnect,
  required Future<void> Function() rebuild,
  required Future<void> Function() settle,
}) async {
  if (await probe()) return true;
  var status = await readStatus();
  if (status.phase == SgConnectionPhase.ready) return false;
  if (status.recovery == SgStatusRecovery.rebuild) {
    await rebuild();
    return probe();
  }

  await settle();
  if (!await reconnect()) {
    await rebuild();
    return probe();
  }
  if (await probe()) return true;
  status = await readStatus();
  if (status.phase == SgConnectionPhase.ready) return false;
  await rebuild();
  return probe();
}

/// Shared recovery path for the SG settings page and the dashboard tile.
Future<SgCoreStatus> recoverSgStatus({
  required Future<void> Function() ensureVpn,
  required Future<SgCoreStatus> Function() readStatus,
  required Future<bool> Function() probe,
  required Future<bool> Function() fallbackProbe,
  required Future<bool> Function() reconnect,
  required Future<void> Function() rebuild,
  required Future<void> Function() settle,
}) async {
  await ensureVpn();
  final status = await readStatus();
  switch (status.recovery) {
    case SgStatusRecovery.none:
      final firstProbeOk = await probe();
      if (!firstProbeOk) {
        final fallbackOk = await fallbackProbe();
        if (!fallbackOk) {
          final accepted = await reconnect();
          final retryPrimaryOk = accepted && await probe();
          final retryFallbackOk = accepted &&
              !retryPrimaryOk &&
              await fallbackProbe();
          if (!retryPrimaryOk && !retryFallbackOk) {
            await rebuild();
            await probe();
          }
        }
      }
      break;
    case SgStatusRecovery.probe:
      await recoverInitialSgConnection(
        probe: probe,
        readStatus: readStatus,
        reconnect: reconnect,
        rebuild: rebuild,
        settle: settle,
      );
      break;
    case SgStatusRecovery.reconnect:
      final accepted = await reconnect();
      if (!accepted) await rebuild();
      await probe();
      break;
    case SgStatusRecovery.rebuild:
      await rebuild();
      await probe();
      break;
  }
  return readStatus();
}
