import 'package:bett_box/common/smart_network_policy.dart';
import 'package:bett_box/widgets/smart_network_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('saving the real settings dialog propagates the new rule', (tester) async {
    String? changed;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: SmartNetworkSettings(rulesJson: '', legacyNetworks: '192.0.2.0/24',
        onChanged: (value) => changed = value)))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加地点规则'));
    await tester.tap(find.text('添加地点规则')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Home');
    await tester.enterText(find.byKey(const ValueKey('rule-ssid')), 'AndroidWifi');
    await tester.tap(find.text('保存规则')); await tester.pumpAndSettle();
    expect(changed, isNotNull);
    final rules = SmartNetworkRule.decode(changed!);
    expect(rules.single.ssid, 'AndroidWifi');
    expect(rules.single.name, 'Home');
    expect(find.text('保存规则'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
