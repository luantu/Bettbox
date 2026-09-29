import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/models/config.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/sg_node_status.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SG title and status match a standard half-width card',
      (tester) async {
    globalState.config = Config(themeProps: defaultThemeProps);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              globalState.theme = CommonTheme.of(context, 1);
              globalState.measure = Measure.of(context, 1);
              return Center(
                child: SizedBox(
                  width: 240,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SgNodeStatusTile(key: ValueKey('sg-card')),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 240,
                        height: getWidgetHeight(1),
                        child: CommonCard(
                          key: const ValueKey('reference-card'),
                          onPressed: () {},
                          info: const Info(
                            iconData: Icons.ballot,
                            label: '参考标题',
                          ),
                          child: Container(
                            width: double.infinity,
                            padding: baseInfoEdgeInsets.copyWith(top: 0),
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              child: Text(
                                '参考状态',
                                style: context.textTheme.bodyMedium?.toLight
                                    .adjustSize(0),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );

    final sgCard = tester.getRect(find.byKey(const ValueKey('sg-card')));
    final referenceCard =
        tester.getRect(find.byKey(const ValueKey('reference-card')));
    final sgHeader = find.descendant(
      of: find.byType(SgNodeStatusTile),
      matching: find.byType(InfoHeader),
    );
    final referenceHeader = find.descendant(
      of: find.byKey(const ValueKey('reference-card')),
      matching: find.byType(InfoHeader),
    );
    expect(sgHeader, findsOneWidget);
    expect(referenceHeader, findsOneWidget);
    final sgTitle = tester.getRect(find.descendant(
      of: sgHeader,
      matching: find.byType(RichText),
    ).first);
    final referenceTitle = tester.getRect(find.descendant(
      of: referenceHeader,
      matching: find.byType(RichText),
    ).first);
    final sgStatus = tester.getRect(find.descendant(
      of: find.byType(SgNodeStatusTile),
      matching: find.byType(Text),
    ).last);
    final referenceStatus = tester.getRect(find.text('参考状态'));

    expect(sgTitle.left - sgCard.left,
        closeTo(referenceTitle.left - referenceCard.left, 0.5));
    expect(sgTitle.top - sgCard.top,
        closeTo(referenceTitle.top - referenceCard.top, 0.5));
    expect(sgStatus.left - sgCard.left,
        closeTo(referenceStatus.left - referenceCard.left, 0.5));
    expect(sgCard.bottom - sgStatus.bottom,
        closeTo(referenceCard.bottom - referenceStatus.bottom, 0.5));
  });
}
