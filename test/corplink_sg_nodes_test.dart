import 'dart:async';
import 'dart:convert';

import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryNodeSecrets implements CorplinkNodeSecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const settings = CorplinkSgSettings(
    enabled: true,
    username: 'test-user',
    password: 'test-password',
    server: 'https://example.invalid',
  );

  test('two servers keep different persistent keys under one login', () async {
    final secrets = _MemoryNodeSecrets();
    final intl = await loadOrCreateCorplinkNodeKeyPair(
      settings,
      'FZ-INT-Node',
      secrets: secrets,
    );
    final fuzhou = await loadOrCreateCorplinkNodeKeyPair(
      settings,
      'FUZHOU-NODE-1',
      secrets: secrets,
    );
    expect(intl.publicKey, isNot(fuzhou.publicKey));
    expect(intl.privateKey, isNot(fuzhou.privateKey));

    final reopened = await loadOrCreateCorplinkNodeKeyPair(
      settings,
      'FZ-INT-Node',
      secrets: secrets,
    );
    expect(reopened.publicKey, intl.publicKey);
    expect(reopened.privateKey, intl.privateKey);

    final otherAccount = await loadOrCreateCorplinkNodeKeyPair(
      const CorplinkSgSettings(
        enabled: true,
        username: 'another-user',
        password: 'test-password',
        server: 'https://example.invalid',
      ),
      'FZ-INT-Node',
      secrets: secrets,
    );
    expect(otherAccount.privateKey, isNot(intl.privateKey));

    final otherUpstream = await loadOrCreateCorplinkNodeKeyPair(
      const CorplinkSgSettings(
        enabled: true,
        username: 'test-user',
        password: 'test-password',
        server: 'https://another.example.invalid',
      ),
      'FZ-INT-Node',
      secrets: secrets,
    );
    expect(otherUpstream.privateKey, isNot(intl.privateKey));
  });

  test('old INTL key migrates without generating a replacement', () async {
    final secrets = _MemoryNodeSecrets();
    final legacyPrivate = base64Encode(List<int>.filled(32, 7));
    final legacyPublic = base64Encode(List<int>.filled(32, 9));
    final key = await loadOrCreateCorplinkNodeKeyPair(
      settings,
      'FZ-INT-Node',
      secrets: secrets,
      legacyAuth: {
        'username': 'test-user',
        'server': 'https://example.invalid',
        'private_key': legacyPrivate,
        'public_key': legacyPublic,
      },
    );
    expect(key.privateKey, legacyPrivate);
    expect(key.publicKey, legacyPublic);
    final reopened = await loadOrCreateCorplinkNodeKeyPair(
      settings,
      'FZ-INT-Node',
      secrets: secrets,
    );
    expect(reopened.privateKey, legacyPrivate);
  });

  test('legacy INTL alias reuses the same saved WireGuard key', () async {
    final secrets = _MemoryNodeSecrets();
    final legacyPrivate = base64Encode(List<int>.filled(32, 7));
    final legacyPublic = base64Encode(List<int>.filled(32, 9));
    final key = await loadOrCreateCorplinkNodeKeyPair(
      settings,
      'FUZHOU_INTL_node',
      secrets: secrets,
      legacyAuth: {
        'username': 'test-user',
        'server': 'https://example.invalid',
        'private_key': legacyPrivate,
        'public_key': legacyPublic,
      },
    );
    expect(key.privateKey, legacyPrivate);
    expect(key.publicKey, legacyPublic);
  });

  test('server and probe validation rejects unsafe names or URLs', () {
    expect(const CorplinkNodeSelection(serverName: '').validationError, isNotNull);
    expect(const CorplinkNodeSelection(serverName: 'A,B').validationError, isNotNull);
    expect(const CorplinkNodeSelection(serverName: 'A\nB').validationError, isNotNull);
    expect(const CorplinkNodeSelection(serverName: 'SG-Node').validationError, isNotNull);
    expect(const CorplinkNodeSelection(serverName: 'SG-OpenAI').validationError, isNotNull);
    expect(const CorplinkNodeSelection(serverName: 'DIRECT').validationError, isNotNull);
    expect(
      const CorplinkNodeSelection(
        serverName: 'FUZHOU-NODE-1',
        healthUrl: 'http://health.example.invalid/',
      ).validationError,
      isNotNull,
    );
    expect(
      const CorplinkNodeSelection(
        serverName: 'FUZHOU-NODE-1',
        healthUrl: 'https://user:password@health.example.invalid/',
      ).validationError,
      isNotNull,
    );
    expect(
      const CorplinkNodeSelection(
        serverName: 'FUZHOU-NODE-1',
        healthUrl: 'https://health.example.invalid/#token',
      ).validationError,
      isNotNull,
    );
    expect(
      const CorplinkNodeSelection(
        serverName: 'FUZHOU-NODE-1',
        healthUrl: 'https://health.example.invalid/ready',
      ).validationError,
      isNull,
    );
  });

  test('missing selection record keeps legacy mode distinct from empty selection', () async {
    final secrets = _MemoryNodeSecrets();
    expect(await loadCorplinkNodeSelections(secrets: secrets), isNull);
    await saveCorplinkNodeSelections(const [], secrets: secrets);
    expect(await loadCorplinkNodeSelections(secrets: secrets), isEmpty);
  });

  test('health URL persists in secure storage, not ordinary preferences', () async {
    final secrets = _MemoryNodeSecrets();
    await saveCorplinkNodeSelections(
      const [CorplinkNodeSelection(
        serverName: 'FUZHOU-NODE-1',
        enabled: true,
        healthUrl: 'https://health.example.invalid/ready',
      )],
      secrets: secrets,
    );
    final loaded = await loadCorplinkNodeSelections(secrets: secrets);
    expect(loaded?.single.healthUrl, 'https://health.example.invalid/ready');

    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(prefs.get(key).toString(), isNot(contains('health.example.invalid')));
    }
  });

  test('probe URL does not carry into another account on the same node', () async {
    final secrets = _MemoryNodeSecrets();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(corplinkSgUsernameKey, 'first-user');
    await prefs.setString(corplinkSgServerKey, 'https://example.invalid');
    await saveCorplinkNodeSelections(
      const [CorplinkNodeSelection(
        serverName: 'FUZHOU-NODE-1',
        healthUrl: 'https://private.example.invalid/ready',
      )],
      secrets: secrets,
    );
    await prefs.setString(corplinkSgUsernameKey, 'second-user');
    final loaded = await loadCorplinkNodeSelections(secrets: secrets);
    expect(loaded?.single.healthUrl, isEmpty);
  });

  test('concurrent node startup shares one account login', () async {
    final coordinator = CorplinkAuthCoordinator();
    final gate = Completer<bool>();
    var logins = 0;
    Future<bool> login() {
      logins++;
      return gate.future;
    }

    final first = coordinator.ensure('test-user|example.invalid', login);
    final second = coordinator.ensure('test-user|example.invalid', login);
    expect(logins, 1);
    gate.complete(true);
    expect(await Future.wait([first, second]), [true, true]);
  });

  test('discovery parser keeps only TCP names in server order', () {
    final names = parseCorplinkVPNNodeSummaries([
      {'name': 'FZ-INT-Node', 'protocolMode': 1},
      {'name': 'UDP-NODE', 'protocolMode': 2},
      {'name': 'FUZHOU-NODE-1', 'protocolMode': 1},
    ]);
    expect(names, ['FZ-INT-Node', 'FUZHOU-NODE-1']);
  });

  test('core discovery error is not cast to a node list or leaked', () {
    expect(
      () => checkedCorplinkNodeListResult('corplink vpn list HTTP 401'),
      throwsA(isA<StateError>()),
    );
    expect(
      () => checkedCorplinkNodeListResult('Cookie=/private/token'),
      throwsA(isA<StateError>().having(
        (error) => error.message.toString(), 'safe message',
        isNot(contains('/private/token')),
      )),
    );
    expect(checkedCorplinkNodeListResult([
      {'name': 'FUZHOU-NODE-1', 'protocolMode': 1},
    ]), hasLength(1));
  });
}
