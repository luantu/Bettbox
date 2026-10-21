import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/views/corplink_management_panel.dart';
import 'package:bett_box/widgets/sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const nodes = [
    CorplinkNodeSelection(serverName: 'Intl-Test', enabled: true),
    CorplinkNodeSelection(serverName: 'Office-Test', enabled: true),
  ];
  const statuses = [
    SgCoreStatus(serverName: 'Intl-Test', present: true, initialized: true,
        ready: true, rebuildRequired: false, closed: false,
        tunnelIp: '198.51.100.2/32', endpoint: '192.0.2.10:34080'),
    SgCoreStatus(serverName: 'Office-Test', present: true, initialized: true,
        ready: false, rebuildRequired: true, closed: false,
        tunnelIp: '198.51.100.3/32', endpoint: '192.0.2.11:34080'),
  ];

  Future<void> showPanel(WidgetTester tester, {
    bool draftDirty = false,
    List<SgCoreStatus> current = statuses,
    Future<void> Function()? restore,
    Future<void> Function(String)? reconnect,
    Future<void> Function()? reauthorize,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CorplinkManagementPanel(
        enabled: true, vpnRunning: true, busy: false,
        nodes: nodes, statuses: current,
        probes: const {}, ipChanges: const {}, updatedAt: null,
        message: '', draftDirty: draftDirty,
        configuration: const Column(children: [
          TextField(key: ValueKey('account-input')),
          Text('选择服务器及设置探针'),
        ]),
        onRestore: restore ?? () async {},
        onReconnectNode: reconnect ?? (_) async {},
        onReauthorize: reauthorize ?? () async {},
      ),
    )));
    await tester.pumpAndSettle();
  }

  testWidgets('first screen prioritizes real node status and hides configuration', (tester) async {
    var checks = 0;
    await showPanel(tester, restore: () async { checks++; });
    expect(find.text('1/2 已连接'), findsOneWidget);
    expect(find.text('Intl-Test'), findsOneWidget);
    expect(find.text('Office-Test'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-input')), findsNothing);
    expect(find.text('选择服务器及设置探针'), findsNothing);
    expect(find.text('192.0.2.10:34080'), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is FilledButton), findsOneWidget);
    await tester.tap(find.text('检查并恢复'));
    await tester.pump();
    expect(checks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('configuration opens deliberately and pending edits do not relabel live nodes', (tester) async {
    await showPanel(tester, draftDirty: true);
    expect(find.text('1/2 已连接'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('corplink-configuration')));
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('account-input')), findsOneWidget);
    expect(find.text('未保存的修改'), findsWidgets);
    expect(find.text('1/2 已连接'), findsOneWidget);
  });

  testWidgets('complete configuration is reachable without scrolling',
      (tester) async {
    await showPanel(tester);

    expect(find.text('编辑完整配置'), findsOneWidget);
    await tester.tap(find.text('编辑完整配置'));
    await tester.pumpAndSettle();

    expect(find.text('飞连完整配置'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-input')), findsOneWidget);
    expect(find.text('选择服务器及设置探针'), findsOneWidget);
  });

  testWidgets('advanced reconnect requires confirmation and targets exactly one node', (tester) async {
    final targets = <String>[];
    await showPanel(tester, reconnect: (name) async { targets.add(name); });
    await tester.ensureVisible(find.byKey(const ValueKey('corplink-advanced')));
    await tester.tap(find.text('高级操作'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重连 Office-Test'));
    await tester.tap(find.text('重连 Office-Test'));
    await tester.pumpAndSettle();
    expect(targets, isEmpty);
    expect(find.textContaining('中断'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(targets, isEmpty);
    await tester.tap(find.text('重连 Office-Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重连'));
    await tester.pumpAndSettle();
    expect(targets, ['Office-Test']);
  });

  testWidgets('unsaved settings block reauthorization rather than applying drafts implicitly', (tester) async {
    var authorizations = 0;
    await showPanel(tester, draftDirty: true,
        reauthorize: () async { authorizations++; });
    await tester.ensureVisible(find.byKey(const ValueKey('corplink-advanced')));
    await tester.tap(find.text('高级操作'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重新授权'));
    await tester.tap(find.text('重新授权'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(authorizations, 0);
    expect(find.textContaining('保存或取消'), findsOneWidget);
  });

  testWidgets('node cards remain readable in a narrow viewport', (tester) async {
    await showPanel(tester);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('1/2 已连接'), findsOneWidget);
  });

  testWidgets('large downloaded route sets use a bounded preview',
      (tester) async {
    final routes = List.generate(
      2000,
      (index) => '10.${index ~/ 256}.${index % 256}.0/24',
    );
    await showPanel(
      tester,
      current: [
        SgCoreStatus(
          serverName: 'Intl-Test',
          present: true,
          initialized: true,
          ready: true,
          rebuildRequired: false,
          closed: false,
          tunnelIp: '198.51.100.2/32',
          endpoint: '192.0.2.10:34080',
          routesPresent: true,
          routeSplit: routes,
        ),
        statuses[1],
      ],
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Intl-Test'));
    await tester.pumpAndSettle();
    expect(find.text('共 2000 条，预览前 8 条'), findsOneWidget);
    expect(find.text(routes.first), findsOneWidget);
    expect(find.text(routes[7]), findsOneWidget);
    expect(find.text(routes[8]), findsNothing);
  });

  testWidgets('full page sheet uses the active theme surface', (tester) async {
    const scheme = ColorScheme.dark(
      surface: Color(0xff101214),
      surfaceContainer: Color(0xff202428),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isMobileViewProvider.overrideWith((ref) => true),
        ],
        child: MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: const AdaptiveSheetScaffold(
            type: SheetType.page,
            title: '飞连 SG-Node',
            body: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.backgroundColor, scheme.surface);
  });
}
