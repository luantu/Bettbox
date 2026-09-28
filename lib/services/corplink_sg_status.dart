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
