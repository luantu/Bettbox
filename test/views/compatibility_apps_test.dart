import 'dart:typed_data';

import 'package:bett_box/services/compatibility_apps.dart';
import 'package:bett_box/views/compatibility_apps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FakeCompatibilityPlatform implements CompatibilityAppsPlatform {
  var permissionRequests = 0;
  var shortcutRequests = 0;
  var launchRequests = 0;

  @override
  Future<CompatibilityAppStatus> readStatus(String packageName) async =>
      const CompatibilityAppStatus(
        installed: true,
        usageAccessGranted: false,
        shortcutSupported: true,
      );

  @override
  Future<Uint8List?> readIcon(String packageName) async => null;

  @override
  Future<bool> openUsageAccessSettings() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<bool> createShortcut(String packageName) async {
    shortcutRequests++;
    return true;
  }

  @override
  Future<bool> launchCompatible(String packageName) async {
    launchRequests++;
    return true;
  }
}

void main() {
  testWidgets('Yadea compatibility page exposes permission shortcut and launch',
      (tester) async {
    final platform = _FakeCompatibilityPlatform();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CompatibilityAppsView(platform: platform)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('雅迪智行'), findsOneWidget);
    expect(find.text('自动恢复权限未开启'), findsOneWidget);
    expect(find.text('创建雅迪智行兼容快捷方式'), findsOneWidget);
    expect(find.text('兼容打开'), findsOneWidget);

    await tester.tap(find.text('授予自动恢复权限'));
    await tester.pump();
    await tester.tap(find.text('创建雅迪智行兼容快捷方式'));
    await tester.pump();
    await tester.tap(find.text('兼容打开'));
    await tester.pump();

    expect(platform.permissionRequests, 1);
    expect(platform.shortcutRequests, 1);
    expect(platform.launchRequests, 1);
  });
}
