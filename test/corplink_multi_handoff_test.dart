import 'package:bett_box/services/corplink_sg_runtime.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('named probe reports HTTPS failure without triggering a reconnect', () async {
    bool? observed;
    final success = await observeCorplinkNodeProbe(
      'Fuzhou-Node-1',
      'https://inside.example.invalid/ready',
      probe: (name, url) async {
        expect(name, 'Fuzhou-Node-1');
        expect(url, 'https://inside.example.invalid/ready');
        return false;
      },
      onProbe: (value) => observed = value,
    );
    expect(success, isFalse);
    expect(observed, isFalse);
  });

  test('network handoff retries only the node whose handshake stayed down', () async {
    final reconnects = <String>[];
    final ensured = <String>[];
    var fuzhouReady = false;
    SgCoreStatus status(String name) => SgCoreStatus(
      serverName: name, present: true, initialized: true,
      ready: name == 'FZ-INT-Node' || fuzhouReady,
      rebuildRequired: false, closed: false,
      tunnelIp: name == 'FZ-INT-Node' ? '10.21.0.2/32' : '10.22.0.3/32',
      endpoint: '',
    );
    final unready = await restoreCorplinkNodesAfterNetworkChange(
      ['FZ-INT-Node', 'FUZHOU-NODE-1'],
      ensureHandshake: (name) async {
        ensured.add(name);
        return status(name).ready;
      },
      readStatus: (name) async => status(name),
      reconnect: (name) async {
        reconnects.add(name);
        fuzhouReady = true;
        return true;
      },
      rebuild: (_) async => false,
    );
    expect(unready, isEmpty);
    expect(reconnects, ['FUZHOU-NODE-1']);
    expect(ensured, containsAll(['FZ-INT-Node', 'FUZHOU-NODE-1']));
  });
}
