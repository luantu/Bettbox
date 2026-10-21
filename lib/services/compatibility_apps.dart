import 'dart:typed_data';

import 'package:bett_box/plugins/app.dart';

const yadeaSmartMotoPackage = 'com.yadea.smartmoto';

class CompatibilityAppStatus {
  const CompatibilityAppStatus({
    required this.installed,
    required this.usageAccessGranted,
    required this.shortcutSupported,
    required this.notificationsEnabled,
    required this.active,
  });

  final bool installed;
  final bool usageAccessGranted;
  final bool shortcutSupported;
  final bool notificationsEnabled;
  final bool active;

  factory CompatibilityAppStatus.fromMap(Map<String, dynamic> value) =>
      CompatibilityAppStatus(
        installed: value['installed'] == true,
        usageAccessGranted: value['usageAccessGranted'] == true,
        shortcutSupported: value['shortcutSupported'] == true,
        notificationsEnabled: value['notificationsEnabled'] == true,
        active: value['active'] == true,
      );
}

abstract class CompatibilityAppsPlatform {
  Future<CompatibilityAppStatus> readStatus(String packageName);
  Future<Uint8List?> readIcon(String packageName);
  Future<bool> openUsageAccessSettings();
  Future<bool> createShortcut(String packageName);
  Future<bool> launchCompatible(String packageName);
  Future<bool> resume();
  Future<bool> keepStopped();
}

class AndroidCompatibilityAppsPlatform implements CompatibilityAppsPlatform {
  const AndroidCompatibilityAppsPlatform();

  @override
  Future<CompatibilityAppStatus> readStatus(String packageName) async =>
      CompatibilityAppStatus.fromMap(
        await app.getCompatibilityAppStatus(packageName),
      );

  @override
  Future<Uint8List?> readIcon(String packageName) =>
      app.getPackageIcon(packageName);

  @override
  Future<bool> openUsageAccessSettings() => app.openUsageAccessSettings();

  @override
  Future<bool> createShortcut(String packageName) =>
      app.createCompatibilityShortcut(packageName);

  @override
  Future<bool> launchCompatible(String packageName) =>
      app.launchCompatibleApp(packageName);

  @override
  Future<bool> resume() => app.resumeCompatibilityApp();

  @override
  Future<bool> keepStopped() => app.keepCompatibilityAppStopped();
}
