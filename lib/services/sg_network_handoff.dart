import 'dart:async';

/// Wait for Android's new physical network route before rekeying WireGuard.
/// onAvailable may run while protected TCP sockets still route over the old
/// network; the latest network event wins.
class SgNetworkHandoffRecovery {
  SgNetworkHandoffRecovery({
    required this.reconnect,
    this.settleDelay = const Duration(seconds: 5),
  });

  final Future<void> Function() reconnect;
  final Duration settleDelay;
  Timer? _timer;
  Future<void>? _inFlight;
  int _generation = 0;

  void networkChanged() {
    final generation = ++_generation;
    _timer?.cancel();
    _timer = Timer(settleDelay, () {
      _timer = null;
      unawaited(_run(generation));
    });
  }

  Future<void> _run(int generation) async {
    if (generation != _generation) return;
    final previous = _inFlight;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // The callback reports its own failure. A newer network event still
        // needs a chance to reconnect after that attempt finishes.
      }
      if (generation != _generation) return;
    }

    final Future<void> current;
    try {
      current = reconnect();
    } catch (_) {
      return;
    }
    _inFlight = current;
    try {
      await current;
    } catch (_) {
      // The service callback logs the concrete error.
    } finally {
      if (identical(_inFlight, current)) _inFlight = null;
    }
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }
}
