import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/clipboard_ext.dart';
import 'package:bett_box/plugins/service.dart' show Service;
import 'package:bett_box/plugins/tile.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import 'application.dart';
import 'clash/core.dart';
import 'clash/lib.dart';
import 'common/common.dart';
import 'common/external_control.dart';
import 'common/smart_network_policy.dart';
import 'models/models.dart';
import 'services/corplink_sg.dart';
import 'services/corplink_sg_nodes.dart';
import 'services/corplink_sg_runtime.dart';
import 'services/corplink_native_nodes.dart';
import 'services/sg_network_handoff.dart';
import 'services/vpn_run_intent.dart';

ReceivePort? _serviceReceiverPort;
ReceivePort? _messageReceiverPort;

Future<void> main(List<String> args) async {
  globalState.isService = false;
  WidgetsFlutterBinding.ensureInitialized();

  if (system.isDesktop &&
      (args.contains('--exit') || args.contains('--restart'))) {
    final command = args.contains('--exit') ? 'exit' : 'restart';
    await _sendControlCommand(command);
    exit(0);
  }

  if (system.isMacOS || appPath.isPortable) {
    final acquire = await singleInstanceLock.acquire();
    if (!acquire) {
      commonPrint.warn(
        'SingleInstanceLock: another instance detected or lock failed, exiting',
      );
      if (!appPath.isPortable) {
        await _sendControlCommand('show');
        await Future.delayed(const Duration(milliseconds: 100));
      }
      exit(0);
    }
  }

  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;

  final version = await system.version;
  await Future.wait([globalState.initApp(version), clashCore.preload()]);

  try {
    await uiManager.initializeUI();
  } catch (e) {
    commonPrint.error('Failed to initialize UI: $e');
  }

  await _runApp();
}

Future<void> _sendControlCommand(String command) async {
  for (int i = 0; i < 5; i++) {
    try {
      await ExternalControl.sendCommand(command);
      commonPrint.log('Sent $command command to running instance');
      return;
    } catch (e) {
      if (i == 4) {
        commonPrint.warn('Failed to send $command command: $e');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}

Future<void> _runApp() async {
  await ensureRustLib();

  if (system.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  await android?.init();

  await window?.init();
  if (system.isWindows) {
    clipboardExt.init();
  }
  HttpOverrides.global = BettboxHttpOverrides();
  runApp(ProviderScope(retry: (_, _) => null, child: const Application()));
}

@pragma('vm:entry-point')
Future<void> _service(List<String> flags) async {
  globalState.isService = true;
  WidgetsFlutterBinding.ensureInitialized();
  await globalState.init();
  // The service isolate has no UI AppController, but it must still receive
  // native START/STOP events to persist actual runtime state.
  Service();

  {
    final automaticQuickStart = flags.contains('quick-auto');
    final quickStart = flags.contains('quick') || automaticQuickStart;
    final bootStart = flags.contains('boot');
    final clashLibHandler = ClashLibHandler();
    final nativeSgNodes = CorplinkNativeNodes((message, timeout) =>
      clashLibHandler.invokeAction(message, timeout: timeout));
    final smartAutoStopLock = Lock();
    Timer? smartAutoStopDebounce;
    var sgMaintenanceInFlight = false;

    Future<void> maintainSgNodes() async {
      if (sgMaintenanceInFlight) return;
      sgMaintenanceInFlight = true;
      try {
        if (!await canMaintainCorplinkNodes()) return;
        final snapshot = await vpn?.getSmartNetworkSnapshot();
        if (SmartNetworkSnapshot.decode(snapshot).isEmpty) return;
        final settings = await CorplinkSgSettings.load();
        if (!settings.enabled) return;
        final selected = await loadCorplinkNodeSelections();
        if (selected == null) return;
        final unready = await restoreCorplinkNodesAfterNetworkChange(
          selected.where((node) => node.enabled).map((node) => node.serverName),
          ensureHandshake: nativeSgNodes.ensure,
          readStatus: nativeSgNodes.readStatus,
          reconnect: nativeSgNodes.reconnect,
          rebuild: nativeSgNodes.rebuild,
          canContinue: canMaintainCorplinkNodes,
        );
        if (await canMaintainCorplinkNodes()) {
          commonPrint.log('[SG maintenance] checked=${selected.where((node) => node.enabled).length} '
              'unready=${unready.length}');
        }
      } catch (error) {
        commonPrint.log('[SG maintenance] ${error.runtimeType}');
      } finally {
        sgMaintenanceInFlight = false;
      }
    }

    Timer.periodic(const Duration(seconds: 45), (_) => unawaited(maintainSgNodes()));

    // Android reports Wi-Fi availability before protected sockets necessarily
    // route over it. The phone reproduced a reconnect that stayed on cellular
    // for over two minutes; a reconnect after Wi-Fi settled moved immediately.
    final networkHandoffRecovery = SgNetworkHandoffRecovery(
      reconnect: () async {
        try {
          if (!await canMaintainCorplinkNodes()) return;
          commonPrint.log('[reconnectTunnels] physical network settled, reconnecting');
          final accepted = await clashLibHandler.reconnectTunnels();
          if (!accepted) {
            commonPrint.log('[reconnectTunnels] no reconnectable outbound');
            return;
          }
          // TCP reset is not a completed WireGuard handshake. Check after
          // the initial handshake window, then retry once if still unready.
          await Future.delayed(const Duration(seconds: 8));
          if (!await canMaintainCorplinkNodes()) return;
          final selectedNodes = await loadCorplinkNodeSelections();
          if (selectedNodes != null) {
            final remaining = await restoreCorplinkNodesAfterNetworkChange(
              selectedNodes.where((node) => node.enabled)
                  .map((node) => node.serverName),
              ensureHandshake: nativeSgNodes.ensure,
              readStatus: nativeSgNodes.readStatus,
              reconnect: nativeSgNodes.reconnect,
              rebuild: nativeSgNodes.rebuild,
              canContinue: canMaintainCorplinkNodes,
            );
            commonPrint.log('[reconnectTunnels] independent SG nodes '
                'still unready=${remaining.length}');
            return;
          }
          var ready = await clashLibHandler.corplinkSgReady();
          final stillRunning = await vpn?.getStatus();
          if (ready == false && stillRunning == true) {
            commonPrint.log('[reconnectTunnels] SG handshake not ready, retrying once');
            final retried = await clashLibHandler.reconnectTunnels();
            if (retried) {
              await Future.delayed(const Duration(seconds: 5));
              ready = await clashLibHandler.corplinkSgReady();
            }
          }
          commonPrint.log('[reconnectTunnels] request accepted; SG handshake ready=$ready');
        } catch (e) {
          commonPrint.log('[reconnectTunnels] failed: $e');
        }
      },
    );

    Future<void> checkSmartAutoStop() async {
      try {
        await smartAutoStopLock.synchronized(() async {
          if (await vpn?.isCompatibilityPaused() == true) return;
          // The service isolate's startup Config is not updated by UI providers.
          // Read the atomic saved config, never write a stale full Config back.
          final vpnProps = await preferences.getSavedVpnProps();
          if (vpnProps == null) return; // unreadable config cannot authorize a transition
          final isSmartStopped = await vpn?.isSmartStopped() ?? false;
          if (!vpnProps.smartAutoStop && !isSmartStopped) return;
          final snapshot = await vpn?.getSmartNetworkSnapshot();
          final decision = SmartNetworkPolicy.evaluate(
            networks: SmartNetworkSnapshot.decode(snapshot),
            enabled: vpnProps.smartAutoStop,
            rulesJson: vpnProps.smartAutoStopRules,
            legacyNetworks: vpnProps.smartAutoStopNetworks,
          );
          final action = decision.action(
            isSmartStopped: isSmartStopped,
            isRunning: await vpn?.getStatus() ?? false,
            userRunIntent: await globalState.getVpnRunIntent(reload: true),
            compatibilityPaused: await vpn?.isCompatibilityPaused() ?? false,
          );
          switch (action) {
            case SmartNetworkAction.stop:
              await vpn?.smartStop();
              break;
            case SmartNetworkAction.resume:
              await vpn?.smartResume(clashLibHandler.getAndroidVpnOptions());
              break;
            case SmartNetworkAction.clearStopped:
              await vpn?.setSmartStopped(false);
              break;
            case SmartNetworkAction.none:
              break;
          }
          if (action != SmartNetworkAction.none) {
            // Do not log the private SSID, rule name, or local addresses.
            commonPrint.log('SmartAutoStop: ${action.name}, ${decision.match.name}');
          }
        });
      } catch (e) {
        commonPrint.warn('Smart auto stop check failed: $e');
      }
    }

    void scheduleSmartAutoStopCheck() {
      smartAutoStopDebounce?.cancel();
      smartAutoStopDebounce = Timer(const Duration(seconds: 1), checkSmartAutoStop);
    }

    // Permission changes and same-subnet Wi-Fi roaming may not change IPs.
    // This low-frequency compensation stays alive in the service when UI closes.
    Timer.periodic(const Duration(seconds: 15), (_) => scheduleSmartAutoStopCheck());

    tile?.addListener(
      _TileListenerWithService(
        onStart: () async {
          await app.tip(appLocalizations.startVpn);
          await globalState.handleStart();
        },
        onStop: () async {
          networkHandoffRecovery.cancel();
          await globalState.setVpnRunIntent(false);
          await app.tip(appLocalizations.stopVpn);
          clashLibHandler.stopListener();
          await vpn?.stop();
          await globalState.setVpnRuntimeState(false);
        },
        onReconnectIpc: () {
          commonPrint.log(
            'Service: reconnectIpc requested, re-establishing IPC',
          );
          _handleMainIpc(clashLibHandler);
        },
      ),
    );

    vpn?.addListener(
      _VpnListenerWithService(
        onSmartAutoStopCheck: () {
          scheduleSmartAutoStopCheck();
          // Native startup also emits this event after installing protection.
          // Start selected SG nodes now, not at the next periodic health tick.
          unawaited(maintainSgNodes());
        },
        onDnsChanged: (String dns) {
          clashLibHandler.updateDns(dns);
        },
        onNetworkChanged: () {
          scheduleSmartAutoStopCheck();
          networkHandoffRecovery.networkChanged();
          unawaited(maintainSgNodes());
        },
      ),
    );

    if (!quickStart && !bootStart) {
      _handleMainIpc(clashLibHandler);
      return;
    }

    final lastRunIntent = await globalState.getVpnRunIntent(reload: true);
    if ((bootStart || automaticQuickStart) &&
        !shouldStartAutomaticVpnService(
          autoRun: globalState.config.appSetting.autoRun,
          lastRunIntent: lastRunIntent,
        )) {
      commonPrint.log(
        'Automatic service start suppressed by settings or explicit user stop.',
      );
      _handleMainIpc(clashLibHandler);
      return;
    }

    commonPrint.log('Executing ${bootStart ? "boot" : "quick"} start sequence');
    await ClashCore.initGeo();
    app.tip(appLocalizations.startVpn);
    final homeDirPath = await appPath.homeDirPath;
    final version = await system.version;
    final clashConfig = globalState.config.patchClashConfig.copyWith.tun(
      enable: false,
    );

    Future(() async {
      try {
        final params = await globalState.getSetupParams(
          pathConfig: clashConfig,
        );
        final profileId = globalState.config.currentProfileId;
        if (profileId == null) {
          return;
        }
        var message = (await clashLibHandler.quickStart(
          InitParams(homeDir: homeDirPath, version: version),
          params,
          globalState.getCoreState(),
        )).message;
        if (message.isNotEmpty) {
          final settings = await CorplinkSgSettings.load();
          if (await hasUsableCorplinkSession(settings)) {
            final fallback = await globalState.getSetupParams(
              pathConfig: clashConfig,
              suppressCorplinkNode: true,
            );
            final retryResult = await clashLibHandler.quickStart(
              InitParams(homeDir: homeDirPath, version: version),
              fallback,
              globalState.getCoreState(),
            );
            if (retryResult.message.isEmpty) {
              commonPrint.log('[CorpLinkSG] quick start continued without SG node');
              message = '';
            }
          }
        }
        if (message.isNotEmpty) {
          commonPrint.error('QuickStart failed with error: $message');
          await vpn?.stop();
          await globalState.setVpnRuntimeState(false);
          return;
        }
        final latestRunIntent = await globalState.getVpnRunIntent(reload: true);
        if (!allowsAutomaticVpnRestart(latestRunIntent)) {
          commonPrint.log('Background VPN start canceled by explicit user stop');
          await vpn?.stop();
          await globalState.setVpnRuntimeState(false);
          return;
        }
        await vpn?.start(clashLibHandler.getAndroidVpnOptions());
        final intentAfterStart = await globalState.getVpnRunIntent(reload: true);
        if (!allowsAutomaticVpnRestart(intentAfterStart)) {
          commonPrint.log('Background VPN start rolled back after explicit user stop');
          await vpn?.stop();
          await globalState.setVpnRuntimeState(false);
          return;
        }
        Future.delayed(const Duration(seconds: 2), checkSmartAutoStop);

        if (globalState.config.vpnProps.networkSpeedNotification) {
          final profile = globalState.config.profiles
              .where((e) => e.id == profileId)
              .firstOrNull;
          final profileName = profile?.label ?? 'Bettbox';
          await vpn?.updateNotificationSpeed(profileName, '↑0B/s ↓0B/s');
        }

        clashLibHandler.startListener();
      } catch (e) {
        commonPrint.error('Fatal error during service background start: $e');
        await vpn?.stop();
        await globalState.setVpnRuntimeState(false);
      }
    });
  }
}

void _handleMainIpc(ClashLibHandler clashLibHandler) {
  final sendPort = IsolateNameServer.lookupPortByName(mainIsolate);
  if (sendPort == null) {
    commonPrint.warn(
      'Service: mainIsolate sendPort not found, IPC unavailable',
    );
    return;
  }

  _serviceReceiverPort?.close();
  _messageReceiverPort?.close();

  _serviceReceiverPort = ReceivePort();
  _serviceReceiverPort!.listen((message) async {
    final res = await clashLibHandler.invokeAction(message);
    _safeSend(sendPort, res);
  });
  _safeSend(sendPort, _serviceReceiverPort!.sendPort);

  _messageReceiverPort = ReceivePort();
  clashLibHandler.attachMessagePort(_messageReceiverPort!.sendPort.nativePort);
  _messageReceiverPort!.listen((message) {
    _safeSend(sendPort, message);
  });

  clashLibHandler.startListener();
}

void _safeSend(SendPort sendPort, dynamic message) {
  try {
    sendPort.send(message);
  } catch (e) {
    commonPrint.warn('Service: IPC send failed: $e');
    final retryPort = IsolateNameServer.lookupPortByName(mainIsolate);
    if (retryPort != null) {
      try {
        retryPort.send(message);
      } catch (_) {}
    }
  }
}

@immutable
class _TileListenerWithService with TileListener {
  final Function() _onStart;
  final Function() _onStop;
  final Function() _onReconnectIpc;

  const _TileListenerWithService({
    required Function() onStart,
    required Function() onStop,
    required Function() onReconnectIpc,
  }) : _onStart = onStart,
       _onStop = onStop,
       _onReconnectIpc = onReconnectIpc;

  @override
  void onStart() => _onStart();

  @override
  void onStop() => _onStop();

  @override
  void onReconnectIpc() => _onReconnectIpc();
}

@immutable
class _VpnListenerWithService with VpnListener {
  final Function(String dns) _onDnsChanged;
  final Function() _onNetworkChanged;
  final Function() _onSmartAutoStopCheck;

  const _VpnListenerWithService({
    required Function(String dns) onDnsChanged,
    required Function() onNetworkChanged,
    required Function() onSmartAutoStopCheck,
  }) : _onDnsChanged = onDnsChanged,
       _onNetworkChanged = onNetworkChanged,
       _onSmartAutoStopCheck = onSmartAutoStopCheck;

  @override
  void onSmartAutoStopCheck() => _onSmartAutoStopCheck();

  @override
  void onDnsChanged(String dns) {
    super.onDnsChanged(dns);
    _onDnsChanged(dns);
  }

  @override
  void onNetworkChanged() {
    super.onNetworkChanged();
    _onNetworkChanged();
  }
}
