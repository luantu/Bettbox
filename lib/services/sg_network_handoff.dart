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

  void networkChanged() {
    _timer?.cancel();
    _timer = Timer(settleDelay, () {
      _timer = null;
      unawaited(reconnect());
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
