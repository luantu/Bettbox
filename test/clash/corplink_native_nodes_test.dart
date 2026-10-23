import 'dart:convert';
import 'package:bett_box/services/corplink_native_nodes.dart';
import 'package:bett_box/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('service isolate runs all node actions directly without the UI core', () async {
    final wasService = globalState.isService;
    globalState.isService = true;
    addTearDown(() => globalState.isService = wasService);
    final requests = <Map<String, dynamic>>[];
    final client = CorplinkNativeNodes((message) async {
      final request = jsonDecode(message) as Map<String, dynamic>;
      requests.add(request);
      return jsonEncode({...request, 'code': 0, 'data':
        request['method'] == 'getCorplinkNodeStatuses' ? [{
          'serverName': 'Office', 'present': true, 'initialized': true,
          'ready': true, 'rebuildRequired': false, 'closed': false,
          'tunnelIp': '192.0.2.2/32', 'endpoint': '198.51.100.1:443',
          'routesPresent': false, 'routeSplit': [], 'routeFull': [], 'routeInvalid': 0,
        }] : true});
    });
    expect(await client.ensure('Office'), isTrue);
    expect((await client.readStatus('Office')).ready, isTrue);
    expect(await client.reconnect('Office'), isTrue);
    expect(await client.rebuild('Office'), isTrue);
    expect(requests.map((r) => r['method']).toList(), [
      'ensureCorplinkNode', 'getCorplinkNodeStatuses',
      'reconnectCorplinkNode', 'rebuildCorplinkNode',
    ]);
    expect(requests.where((r) => r['method'] != 'getCorplinkNodeStatuses')
      .every((r) => r['data'] == 'Office'), isTrue);
    expect(requests.map((r) => r['id']).toSet().length, 4);
  });
  test('service action errors and mismatched replies are not healthy nodes', () async {
    for (final invalid in ['error', 'wrongId', 'wrongMethod']) {
      final client = CorplinkNativeNodes((message) async {
        final request = jsonDecode(message) as Map<String, dynamic>;
        return jsonEncode({...request, 'data': true, 'code': invalid == 'error' ? -1 : 0,
          if (invalid == 'wrongId') 'id': 'stale',
          if (invalid == 'wrongMethod') 'method': 'getMemory'});
      });
      await expectLater(client.ensure('Office'), throwsStateError);
    }
  });
}
