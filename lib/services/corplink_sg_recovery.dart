import 'dart:async';

enum SgRecoveryAction { none, reconnect, rebuild }

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
