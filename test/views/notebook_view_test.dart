import 'package:bett_box/views/proxies/notebook.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only watched selectors can enable automatic switching', (
    tester,
  ) async {
    final changes = <Map<String, Object?>>[];
    final selector = <String, Object?>{
      'name': 'Selector test',
      'type': 'Selector',
      'watched': true,
      'autoSwitch': false,
      'members': [
        {'name': 'KR01', 'verdict': 'available', 'delay': 12},
      ],
    };
    final state = <String, Object?>{
      'profile': 'test-profile',
      'ready': true,
      'watchedCount': 2,
      'groups': [
        selector,
        {
          'name': 'Fallback test',
          'type': 'Fallback',
          'watched': true,
          'autoSwitch': false,
        },
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotebookView(
            readState: () async => state,
            updateState: (request) async {
              changes.add(request);
              if (request['autoSwitch'] == true) selector['autoSwitch'] = true;
              return state;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final switches = tester.widgetList<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Switch automatically on failure'),
    );
    expect(switches, hasLength(2));
    expect(switches.first.onChanged, isNotNull);
    expect(switches.last.onChanged, isNull);
    expect(find.text('12 ms'), findsOneWidget);

    await tester.tap(find.text('Switch automatically on failure').first);
    await tester.pumpAndSettle();
    expect(changes, [
      {'profile': 'test-profile', 'group': 'Selector test', 'autoSwitch': true},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('force request remains available while metadata is missing', (
    tester,
  ) async {
    final changes = <Map<String, Object?>>[];
    final state = <String, Object?>{
      'profile': 'restoring-profile',
      'ready': false,
      'watchedCount': 1,
      'groups': [],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotebookView(
            readState: () async => state,
            updateState: (request) async {
              changes.add(request);
              return {...state, 'pending': true};
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(changes, [
      {'profile': 'restoring-profile', 'force': true},
    ]);
    await tester.pumpWidget(const SizedBox());
  });
}
