enum SgRecoveryAction { none, reconnect, reauthorize }

/// Keeps periodic health checks from turning a transient network outage into
/// a reconnect or login storm. One successful probe resets the sequence.
class SgRecoveryPolicy {
  int _failures = 0;
  int _recoveryAttempts = 0;
  DateTime? _nextAllowedAt;

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
    // Reauthentication is expensive. After it has been attempted once,
    // require a longer quiet period before another attempt.
    _failures = 0;
    _nextAllowedAt = now.add(const Duration(minutes: 5));
    return SgRecoveryAction.reauthorize;
  }
}
