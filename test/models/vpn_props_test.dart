import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('malformed SSID field is isolated from the rest of a full Config', () {
    for (final invalid in [[], {}, 123, '{broken']) {
      final original = Config(themeProps: defaultThemeProps,
        nodeExcludeFilter: 'preserve-me',
        vpnProps: const VpnProps(smartAutoStop: true,
          smartAutoStopNetworks: '192.168.110.0/24', bypassPrivateRoute: false,
          accessControl: AccessControl(enable: true, rejectList: ['example.app'])));
      final json = jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
      (json['vpnProps'] as Map)['smartAutoStopRules'] = invalid;
      final restored = Config.compatibleFromJson(json);
      expect(restored.nodeExcludeFilter, 'preserve-me');
      expect(restored.vpnProps.smartAutoStopNetworks, '192.168.110.0/24');
      expect(restored.vpnProps.bypassPrivateRoute, isFalse);
      expect(restored.vpnProps.accessControl.rejectList, ['example.app']);
      expect(restored.vpnProps.smartAutoStopRules, isNotEmpty);
    }
  });
  test('old IP rules survive adding and round-tripping SSID rules', () {
    final old = VpnProps.fromJson({
      'smartAutoStop': true,
      'smartAutoStopNetworks': '192.168.110.0/24,gateway:192.168.111.1',
      'bypassPrivateRoute': false,
    });
    expect(old.smartAutoStopRules, '');
    final updated = old.copyWith(smartAutoStopRules:
      '[{"id":"home","name":"家里","ssid":"Home WiFi","enabled":true,"networks":""}]');
    final restored = VpnProps.fromJson(
      jsonDecode(jsonEncode(updated.toJson())) as Map<String, dynamic>);
    expect(restored.smartAutoStopNetworks, '192.168.110.0/24,gateway:192.168.111.1');
    expect(restored.smartAutoStopRules, updated.smartAutoStopRules);
    expect(restored.smartAutoStop, isTrue);
    expect(restored.bypassPrivateRoute, isFalse);
  });
  group('VpnProps 托盘点击行为', () {
    test('默认保留托盘增强关闭，左键显示面板、右键显示菜单', () {
      const props = VpnProps();

      expect(props.trayEnhancement, isFalse);
      expect(props.trayLeftClickBehavior, TrayClickBehavior.showPanel);
      expect(props.trayRightClickBehavior, TrayClickBehavior.showMenu);
    });

    test('序列化后能够独立恢复左右键设置及托盘增强设置', () {
      const props = VpnProps(
        trayEnhancement: true,
        trayLeftClickBehavior: TrayClickBehavior.showMenu,
        trayRightClickBehavior: TrayClickBehavior.showPanel,
      );

      final restored = VpnProps.fromJson(
        jsonDecode(jsonEncode(props.toJson())) as Map<String, dynamic>,
      );

      expect(restored.trayEnhancement, isTrue);
      expect(restored.trayLeftClickBehavior, TrayClickBehavior.showMenu);
      expect(restored.trayRightClickBehavior, TrayClickBehavior.showPanel);
    });
  });
}
