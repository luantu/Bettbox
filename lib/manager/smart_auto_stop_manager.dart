import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/smart_network_policy.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

class SmartAutoStopManager extends ConsumerStatefulWidget {
  final Widget child;
  const SmartAutoStopManager({super.key, required this.child});
  @override
  ConsumerState<SmartAutoStopManager> createState() => _SmartAutoStopManagerState();
}

class _SmartAutoStopManagerState extends ConsumerState<SmartAutoStopManager>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  final _checkLock = Lock();
  Timer? _debounce;
  Timer? _syncTimer;
  late final NativeEventCallback _nativeEventCallback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeEventCallback = (method, arguments) async {
      if (method == 'networkChanged' || method == 'runStateChanged') {
        await _syncSmartStopped();
        _scheduleCheck();
        final smartOnly = arguments is Map && arguments['smartNetworkOnly'] == true;
        if (method == 'networkChanged' && !smartOnly) _flushDnsOnNetworkChanged();
      } else if (method == 'quickResponse' && ref.read(vpnSettingProvider).quickResponse) {
        final startTime = globalState.startTime;
        if (startTime != null && DateTime.now().difference(startTime) < const Duration(seconds: 3)) return;
        clashCore.closeConnections();
      }
    };
    service?.addNativeEventCallback(_nativeEventCallback);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((_) => _scheduleCheck());
    ref.listenManual(vpnSettingProvider, (prev, next) {
      if (prev?.smartAutoStop != next.smartAutoStop ||
          prev?.smartAutoStopNetworks != next.smartAutoStopNetworks ||
          prev?.smartAutoStopRules != next.smartAutoStopRules) {
        _saveAndCheck();
      }
    });
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _syncSmartStopped();
      if (!system.isAndroid) _scheduleCheck();
    });
    _syncSmartStopped();
    _scheduleCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncSmartStopped();
      _scheduleCheck();
    }
  }

  Future<void> _saveAndCheck() async {
    // Await durable settings before asking the service isolate to reload them.
    await globalState.appController.savePreferences();
    if (mounted) _scheduleCheck();
  }

  Future<void> _syncSmartStopped() async {
    if (!system.isAndroid) return;
    try {
      final stopped = await service?.isSmartStopped() ?? false;
      final running = await service?.getStatus() ?? false;
      if (!mounted) return;
      final wasStopped = ref.read(isSmartStoppedProvider);
      ref.read(isSmartStoppedProvider.notifier).set(stopped);
      if (stopped && !wasStopped) {
        globalState.startTime = null;
        clashCore.resetTraffic();
        ref.read(trafficsProvider.notifier).clear();
        ref.read(totalTrafficProvider.notifier).value = Traffic();
        ref.read(runTimeProvider.notifier).value = null;
      } else if (wasStopped && !stopped && running) {
        globalState.startTime = DateTime.now();
        ref.read(runTimeProvider.notifier).value = 0;
        globalState.appController.addCheckIpNumDebounce();
      }
    } catch (_) {}
  }

  void _flushDnsOnNetworkChanged() {
    if (!ref.read(appSettingProvider).flushDnsOnNetworkChange) return;
    final startTime = globalState.startTime;
    if (startTime == null || DateTime.now().difference(startTime) < const Duration(seconds: 3)) return;
    globalState.appController.flushDns();
  }

  void _scheduleCheck() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _checkCurrentNetwork);
  }

  Future<void> _checkCurrentNetwork() async {
    if (system.isAndroid) {
      // Android has one owner: the service isolate, also while this UI is closed.
      // It checks isCompatibilityPaused() and current run intent before acting.
      await service?.checkSmartAutoStop();
      return;
    }
    await _checkLock.synchronized(() async {
      final props = ref.read(vpnSettingProvider);
      final ip = await utils.getLocalIpAddress();
      final gateways = await utils.getLocalGateways();
      final decision = SmartNetworkPolicy.evaluate(
        enabled: props.smartAutoStop, legacyNetworks: props.smartAutoStopNetworks,
        networks: ip == null && gateways.isEmpty ? [] : [SmartNetworkSnapshot(
          id: 'desktop', selected: true, transport: 'other',
          ips: ip == null ? [] : [ip], gateways: gateways)],
      );
      final action = decision.action(isSmartStopped: ref.read(isSmartStoppedProvider),
        isRunning: ref.read(runTimeProvider) != null || globalState.isStart,
        userRunIntent: await globalState.getVpnRunIntent(reload: true));
      if (!mounted) return;
      if (action == SmartNetworkAction.stop) {
        ref.read(isSmartStoppedProvider.notifier).set(true);
        await globalState.appController.updateStatus(false, recordRunIntent: false);
      } else if (action == SmartNetworkAction.resume) {
        ref.read(isSmartStoppedProvider.notifier).set(false);
        await globalState.appController.updateStatus(true, recordRunIntent: false);
      } else if (action == SmartNetworkAction.clearStopped) {
        ref.read(isSmartStoppedProvider.notifier).set(false);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel(); _syncTimer?.cancel();
    _connectivitySubscription?.cancel();
    service?.removeNativeEventCallback(_nativeEventCallback);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => widget.child;
}
