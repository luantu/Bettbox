import 'dart:convert';
import 'dart:io';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    home = await Directory.systemTemp.createTemp('bettbox_smart_network_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => home.path);
  });
  tearDownAll(() => home.delete(recursive: true));

  test('parallel saves end with latest rules in both file and mirror', () async {
    final first = Config(themeProps: defaultThemeProps,
      vpnProps: const VpnProps(smartAutoStop: true, smartAutoStopNetworks: '192.168.110.0/24'));
    final latest = first.copyWith.vpnProps(smartAutoStop: false, smartAutoStopRules: '[]');
    final results = await Future.wait([preferences.saveConfig(first), preferences.saveConfig(latest)]);
    expect(results, [true, true]);
    final file = jsonDecode(await File(await appPath.appConfigPath).readAsString()) as Map;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final mirror = jsonDecode(prefs!.getString(configKey)!) as Map;
    expect((file['vpnProps'] as Map)['smartAutoStop'], isFalse);
    expect((mirror['vpnProps'] as Map)['smartAutoStop'], isFalse);
    expect((await preferences.getSavedVpnProps())?.smartAutoStopNetworks, '192.168.110.0/24');
  });
  test('service reads saved settings without restoring an old profile mirror', () async {
    final empty = Config(themeProps: defaultThemeProps,
      nodeExcludeFilter: 'unchanged', vpnProps: const VpnProps(smartAutoStop: false));
    expect(await preferences.saveConfig(empty), isTrue);
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs!.setString(configKey, jsonEncode(empty.copyWith(
      profiles: [const Profile(id: 'old', autoUpdateDuration: Duration(hours: 1))],
      vpnProps: const VpnProps(smartAutoStop: true))));
    final before = await File(await appPath.appConfigPath).readAsString();
    expect((await preferences.getSavedVpnProps())?.smartAutoStop, isFalse);
    expect(await File(await appPath.appConfigPath).readAsString(), before);
  });
}
