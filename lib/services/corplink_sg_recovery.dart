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
    bool waitForNative = true,
    Duration timeout = const Duration(seconds: 10),
    int maxChecks = 40,
  }) {
    if (maxChecks < 1) throw ArgumentError.value(maxChecks, 'maxChecks');
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    final active = _inFlight;
    if (active != null) return active;
    final completer = Completer<bool>();
    _inFlight = completer.future;
    final elapsed = Stopwatch()..start();
    Future<T> bounded<T>(Future<T> Function() action) {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('VPN startup deadline');
      return action().timeout(remaining);
    }
    () async {
      try {
        if (!waitForNative) {
          // Preserve desktop/proxy-only startup semantics (including their
          // own authorization flows); this deadline is for Android TUN startup.
          await requestStart();
          completer.complete(true);
          return;
        }
        if (await bounded(isNativeReady)) {
          completer.complete(true);
          return;
        }
        await bounded(requestStart);
        for (var attempt = 0; attempt < maxChecks; attempt++) {
          if (await bounded(isNativeReady)) {
            completer.complete(true);
            return;
          }
          if (attempt + 1 < maxChecks) await bounded(settle);
        }
        completer.complete(false);
      } on TimeoutException {
        completer.complete(false);
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        if (identical(_inFlight, completer.future)) _inFlight = null;
      }
    }();
    return completer.future;
  }
}

/// Runs the external Android login helper outside Bettbox's own TUN, then
/// restores the same native VPN intent before configuration is applied.
class CorplinkAuthorizationNetworkGate {
  Future<T> run<T>({
    required Future<int?> Function() beginBypass,
    required Future<T> Function() action,
    required Future<bool> Function(int token) endBypass,
    required Future<bool> Function() isNativeReady,
    required Future<void> Function() settle,
    Duration timeout = const Duration(seconds: 10),
    int maxChecks = 40,
  }) async {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    if (maxChecks < 1) throw ArgumentError.value(maxChecks, 'maxChecks');

    final token = await beginBypass();
    if (token == null) return action();

    late T value;
    Object? actionError;
    StackTrace? actionStack;
    try {
      value = await action();
    } catch (error, stack) {
      actionError = error;
      actionStack = stack;
    }

    Object? restoreError;
    StackTrace? restoreStack;
    try {
      bool? resumed;
      Object? lastEndError;
      StackTrace? lastEndStack;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          resumed = await endBypass(token);
          lastEndError = null;
          lastEndStack = null;
          break;
        } catch (error, stack) {
          lastEndError = error;
          lastEndStack = stack;
          if (attempt < 2) await settle();
        }
      }
      if (lastEndError != null) {
        Error.throwWithStackTrace(lastEndError, lastEndStack!);
      }
      if (resumed == true) {
        final elapsed = Stopwatch()..start();
        var ready = false;
        for (var attempt = 0; attempt < maxChecks; attempt++) {
          final remaining = timeout - elapsed.elapsed;
          if (remaining <= Duration.zero) break;
          ready = await isNativeReady().timeout(remaining);
          if (ready) break;
          if (attempt + 1 < maxChecks) await settle().timeout(remaining);
        }
        if (!ready) throw StateError('ANDROID_VPN_RESUME_TIMEOUT');
      }
    } catch (error, stack) {
      restoreError = error;
      restoreStack = stack;
    }

    if (actionError != null && restoreError != null) {
      throw CorplinkAuthorizationRecoveryException(
        actionError.runtimeType.toString(),
        restoreError.runtimeType.toString(),
      );
    }
    if (actionError != null) {
      Error.throwWithStackTrace(actionError, actionStack!);
    }
    if (restoreError != null) {
      Error.throwWithStackTrace(restoreError, restoreStack!);
    }
    return value;
  }
}

class CorplinkAuthorizationRecoveryException implements Exception {
  const CorplinkAuthorizationRecoveryException(
    this.authorizationErrorType,
    this.restoreErrorType,
  );

  final String authorizationErrorType;
  final String restoreErrorType;

  @override
  String toString() =>
      'CorpLink authorization failed ($authorizationErrorType) and '
      'Android VPN restoration failed ($restoreErrorType)';
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
