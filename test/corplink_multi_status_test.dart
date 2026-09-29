import 'package:bett_box/services/corplink_sg_recovery.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const readyIntl = SgCoreStatus(
    serverName: 'FZ-INT-Node',
    present: true, initialized: true, ready: true,
    rebuildRequired: false, closed: false,
    tunnelIp: '10.21.0.2/32', endpoint: '192.0.2.10:34080',
  );
  const brokenFuzhou = SgCoreStatus(
    serverName: 'FUZHOU-NODE-1',
    present: true, initialized: true, ready: false,
    rebuildRequired: true, closed: false,
    tunnelIp: '10.22.0.3/32', endpoint: '192.0.2.11:34081',
  );

  test('aggregate status counts independent nodes without leaking endpoints', () {
    final summary = summarizeCorplinkNodes(
      [readyIntl, brokenFuzhou],
      ['FZ-INT-Node', 'FUZHOU-NODE-1'],
    );
    expect(summary.ready, 1);
    expect(summary.total, 2);
    expect(summary.label, '1/2 已连接');
    expect(summary.label, isNot(contains('192.0.2.')));
  });

  test('a blocked custom website does not reconnect a ready tunnel', () async {
    var reconnects = 0;
    var rebuilds = 0;
    final status = await recoverCorplinkNodeStatus(
      serverName: 'FZ-INT-Node',
      readStatus: () async => readyIntl,
      ensureHandshake: (_) async => true,
      reconnect: (_) async { reconnects++; return true; },
      rebuild: (_) async { rebuilds++; return true; },
      probeUrl: 'https://blocked.example.invalid/ready',
      probe: (_, __) async => false,
    );
    expect(status.ready, isTrue);
    expect(reconnects, 0);
    expect(rebuilds, 0);
  });

  test('one node requiring rebuild does not invoke another node action', () async {
    final rebuilt = <String>[];
    await recoverCorplinkNodeStatus(
      serverName: 'FUZHOU-NODE-1',
      readStatus: () async => brokenFuzhou,
      ensureHandshake: (_) async => false,
      reconnect: (_) async => false,
      rebuild: (name) async { rebuilt.add(name); return true; },
    );
    expect(rebuilt, ['FUZHOU-NODE-1']);
  });

  test('blank health URL starts handshake without a public website probe', () async {
    final handshake = <String>[];
    var webProbes = 0;
    const pending = SgCoreStatus(
      serverName: 'FZ-INT-Node', present: true,
      initialized: false, ready: false,
      rebuildRequired: false, closed: false,
      tunnelIp: '10.21.0.2/32', endpoint: '192.0.2.10:34080',
    );
    var current = pending;
    final result = await recoverCorplinkNodeStatus(
      serverName: 'FZ-INT-Node',
      readStatus: () async => current,
      ensureHandshake: (name) async {
        handshake.add(name);
        current = readyIntl;
        return true;
      },
      reconnect: (_) async => false,
      rebuild: (_) async => false,
      probe: (_, __) async { webProbes++; return false; },
    );
    expect(result.ready, isTrue);
    expect(handshake, ['FZ-INT-Node']);
    expect(webProbes, 0);
  });

  test('recovery cooldown is independent for each selected server', () {
    final policies = <String, SgRecoveryPolicy>{};
    SgRecoveryPolicy forName(String name) =>
        policies.putIfAbsent(name, SgRecoveryPolicy.new);
    final now = DateTime(2026, 9, 29);
    for (var i = 0; i < 3; i++) {
      forName('FZ-INT-Node').recordProbe(false, now);
    }
    expect(forName('FZ-INT-Node').recordProbe(false, now), SgRecoveryAction.none);
    expect(forName('FUZHOU-NODE-1').recordProbe(false, now), SgRecoveryAction.none);
    expect(forName('FUZHOU-NODE-1').recordProbe(false, now), SgRecoveryAction.none);
    expect(forName('FUZHOU-NODE-1').recordProbe(false, now), SgRecoveryAction.reconnect);
  });
}
