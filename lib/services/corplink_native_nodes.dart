import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/enum/enum.dart';

import 'corplink_sg_status.dart';

/// Service-isolate node operations over the existing native action port.
/// Deliberately independent of ClashCore, which owns the UI-side IPC client.
class CorplinkNativeNodes {
  CorplinkNativeNodes(this.invokeAction);

  final Future<String> Function(String, Duration) invokeAction;
  int _sequence = 0;

  Future<dynamic> _invoke(String method, String? name, Duration timeout) async {
    final id =
        'sg-native-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final message = jsonEncode({'id': id, 'method': method, 'data': name});
    final reply = decodeActionResult(
      await invokeAction(message, timeout).timeout(timeout),
    );
    if (reply == null ||
        reply.id != id ||
        reply.method.name != method ||
        reply.code != ResultType.success) {
      throw StateError('CORPLINK_NATIVE_ACTION_FAILED');
    }
    return reply.data;
  }

  Future<SgCoreStatus> readStatus(String name) async {
    for (final status in await readStatuses()) {
      if (status.serverName == name) return status;
    }
    return SgCoreStatus(
      serverName: name,
      present: false,
      initialized: false,
      ready: false,
      rebuildRequired: false,
      closed: false,
      tunnelIp: '',
      endpoint: '',
    );
  }

  Future<List<SgCoreStatus>> readStatuses() async {
    final data = await _invoke(
      'getCorplinkNodeStatuses',
      null,
      const Duration(seconds: 4),
    );
    if (data is! List) throw StateError('CORPLINK_NATIVE_STATUS_UNAVAILABLE');
    return [
      for (final value in data)
        if (value is Map) SgCoreStatus.fromJson(value),
    ];
  }

  Future<bool> ensure(String name) async =>
      await _invoke('ensureCorplinkNode', name, const Duration(seconds: 25)) ==
      true;
  Future<bool> reconnect(String name) async =>
      await _invoke(
        'reconnectCorplinkNode',
        name,
        const Duration(seconds: 4),
      ) ==
      true;
  Future<bool> rebuild(String name) async =>
      await _invoke('rebuildCorplinkNode', name, const Duration(seconds: 50)) ==
      true;
}
