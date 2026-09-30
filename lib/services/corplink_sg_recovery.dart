import 'dart:async';

enum SgRecoveryAction { none, reconnect, rebuild }

/// Android accepts a VPN start before its TUN/protect callback is installed.
/// All named nodes share this barrier; no handshake may race that transition.
class CorplinkVpnStartGate {
  Future<bool>? _inFlight;

  Future<bool> ensureReady({
    required Future<bool> Function() isNativeReady,
    required Future<void> Function() requestStart,
    required Future<void> Function() settle,
    int maxChecks = 40,
  }) {
    if (maxChecks < 1) throw ArgumentError.value(maxChecks, 'maxChecks');
    final active = _inFlight;
    if (active != null) return active;
    final completer = Completer<bool>();
    _inFlight = completer.future;
    () async {
      try {
        if (await isNativeReady()) {
          completer.complete(true);
          return;
        }
        await requestStart();
        for (var attempt = 0; attempt < maxChecks; attempt++) {
          if (await isNativeReady()) {
            completer.complete(true);
            return;
          }
          if (attempt + 1 < maxChecks) await settle();
        }
        completer.complete(false);
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _inFlight = null;
      }
    }();
    return completer.future;
  }
}

bool shouldAutoAuthorizeAfterSgSetup({
  required bool authRejected,
  required bool authMatches,
  required bool cookiePresent,
}) =>
    authRejected || !authMatches || !cookiePresent;

/// Captures the AppController's normal Zone before its reentrant core lock is
/// acquired. Futures and timers created inside a completed synchronized Zone
/// carry a stale lock level and cannot safely re-enter that lock later.
class SgDeferredScheduler {
  final Zone _ownerZone = Zone.current;

  T run<T>(T Function() action) => _ownerZone.run(action);

  void schedule(Future<void> Function() action) {
    _ownerZone.run(() {
      unawaited(Future<void>(action));
    });
  }
}

/// Keeps periodic health checks from turning a transient network outage into
/// a reconnect or login storm. One successful probe resets the sequence.
class SgRecoveryPolicy {
  int _failures = 0;
  int _recoveryAttempts = 0;
  DateTime? _nextAllowedAt;

  SgRecoveryAction recordRebuildRequired(DateTime now) {
    if (_nextAllowedAt != null && now.isBefore(_nextAllowedAt!)) {
      return SgRecoveryAction.none;
    }
    _failures = 0;
    _recoveryAttempts = 2;
    _nextAllowedAt = now.add(const Duration(minutes: 5));
    return SgRecoveryAction.rebuild;
  }

  SgRecoveryAction recordProbe(bool healthy, DateTime now) {
    if (healthy) {
      _failures = 0;
      _recoveryAttempts = 0;
      _nextAllowedAt = null;
      return SgRecoveryAction.none;
    }

    if (_failures < 3) _failures++;
    if (_failures < 3 ||
        (_nextAllowedAt != null && now.isBefore(_nextAllowedAt!))) {
      return SgRecoveryAction.none;
    }

    _recoveryAttempts++;
    if (_recoveryAttempts == 1) {
      _failures = 2;
      _nextAllowedAt = now.add(const Duration(seconds: 30));
      return SgRecoveryAction.reconnect;
    }
    // Rebuild the outbound/IP stack with the saved authorization. A failed
    // website probe must never force a fresh password login.
    _failures = 0;
    _nextAllowedAt = now.add(const Duration(minutes: 5));
    return SgRecoveryAction.rebuild;
  }
}
