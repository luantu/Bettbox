import 'dart:typed_data';

import 'package:bett_box/plugins/app.dart';

const yadeaSmartMotoPackage = 'com.yadea.smartmoto';

class CompatibilityAppStatus {
  const CompatibilityAppStatus({
    required this.installed,
    required this.usageAccessGranted,
    required this.shortcutSupported,
  });

  final bool installed;
  final bool usageAccessGranted;
  final bool shortcutSupported;

  factory CompatibilityAppStatus.fromMap(Map<String, dynamic> value) =>
      CompatibilityAppStatus(
        installed: value['installed'] == true,
        usageAccessGranted: value['usageAccessGranted'] == true,
        shortcutSupported: value['shortcutSupported'] == true,
      );
}

abstract class CompatibilityAppsPlatform {
  Future<CompatibilityAppStatus> readStatus(String packageName);
  Future<Uint8List?> readIcon(String packageName);
  Future<bool> openUsageAccessSettings();
  Future<bool> createShortcut(String packageName);
  Future<bool> launchCompatible(String packageName);
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
}
