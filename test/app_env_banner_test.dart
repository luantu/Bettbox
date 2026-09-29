import 'package:bett_box/manager/app_manager.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a pre-release SG build can hide the environment ribbon',
      (tester) async {
    globalState.isPre = true;
    await tester.pumpWidget(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AppEnvManager(
        showEnvironmentBanner: false,
        child: Scaffold(body: Text('SG dashboard')),
      ),
    ));

    expect(find.text('SG dashboard'), findsOneWidget);
    expect(find.byType(Banner), findsNothing);
    expect(globalState.isPre, isTrue);
  });
}
