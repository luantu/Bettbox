import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:bett_box/state.dart';

Future<SgCoreStatus> readCorplinkSgStatus() async =>
    SgCoreStatus.fromJson(await clashCore.getCorplinkSgStatus());

Future<bool> probeCorplinkSgChatGpt() async {
  try {
    final delay = await clashCore.getDelay(
      'https://chatgpt.com/robots.txt', 'SG-Node');
    return delay.value != null && delay.value! > 0;
  } catch (_) {
    return false;
  }
}

Future<SgCoreStatus> refreshCorplinkSgStatus({
  Future<bool> Function()? probe,
}) =>
    recoverSgStatus(
      ensureVpn: () async {
        if (!globalState.isStart) {
          await globalState.appController.updateStatus(true);
        }
      },
      readStatus: readCorplinkSgStatus,
      probe: probe ?? probeCorplinkSgChatGpt,
      reconnect: clashCore.reconnectCorplinkTunnel,
      rebuild: () => globalState.appController.applyProfile(silence: true),
      settle: () => Future<void>.delayed(const Duration(seconds: 2)),
    );
