enum SgConnectionPhase { missing, waitingForTraffic, connecting, ready, needsRebuild }

enum SgStatusRecovery { none, probe, reconnect, rebuild }

/// Read-only core telemetry. This model intentionally has no auth material.
class SgCoreStatus {
  const SgCoreStatus({
    required this.present,
    required this.initialized,
    required this.ready,
    required this.rebuildRequired,
    required this.closed,
    required this.tunnelIp,
    required this.endpoint,
  });

  final bool present;
  final bool initialized;
  final bool ready;
  final bool rebuildRequired;
  final bool closed;
  final String tunnelIp;
  final String endpoint;

  factory SgCoreStatus.fromJson(Map<dynamic, dynamic> json) => SgCoreStatus(
        present: json['present'] == true,
        initialized: json['initialized'] == true,
        ready: json['ready'] == true,
        rebuildRequired: json['rebuildRequired'] == true,
        closed: json['closed'] == true,
        tunnelIp: json['tunnelIp'] as String? ?? '',
        endpoint: json['endpoint'] as String? ?? '',
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
        final accepted = await reconnect();
        final retryOk = accepted && await probe();
        if (!retryOk) {
          await rebuild();
          await probe();
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
