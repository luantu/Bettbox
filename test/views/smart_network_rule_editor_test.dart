import 'package:bett_box/common/smart_network_policy.dart';
import 'package:bett_box/widgets/smart_network_rule_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('editor always exposes Save without network discovery', (tester) async {
    SmartNetworkRule? saved;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SmartNetworkRuleEditor(
      initial: const SmartNetworkRule(id: 'home', name: '家里', ssid: 'Home'),
      onSaved: (value) => saved = value,
    ))));
    await tester.pumpAndSettle();
    expect(find.text('保存规则'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('rule-ssid')), ' Wi-Fi,中文 ');
    await tester.enterText(find.byKey(const ValueKey('rule-networks')), '192.168.110.0/24');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect(saved?.ssid, ' Wi-Fi,中文 ');
    expect(saved?.networks, '192.168.110.0/24');
    expect(saved?.id, 'home');
  });
  testWidgets('empty and malformed conditions cannot be saved', (tester) async {
    SmartNetworkRule? saved;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SmartNetworkRuleEditor(
      initial: const SmartNetworkRule(id: 'home', name: '家里'),
      onSaved: (value) => saved = value,
    ))));
    await tester.tap(find.text('保存规则')); await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('请填写 SSID 或 IP／网关条件'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('rule-networks')), '1192.168.1.0/24');
    await tester.tap(find.text('保存规则')); await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.textContaining('IP／网关格式错误'), findsOneWidget);
  });
}
