import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/sg_node_status.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SG title and status match a standard half-width card',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            height: globalState.measure.titleMediumHeight + 16,
                            padding: baseInfoEdgeInsets.copyWith(bottom: 0),
                            child: Row(children: [
                              const Icon(Icons.network_check),
                              const SizedBox(width: 8),
                              Text('参考标题',
                                  style: context.textTheme.titleSmall),
                            ]),
                          ),
                          Container(
                            padding: baseInfoEdgeInsets.copyWith(top: 0),
                            child: SizedBox(
                              height: globalState.measure.bodyMediumHeight + 2,
                              child: Text('参考状态',
                                  style: context.textTheme.bodyMedium),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    ));

    final sgCard = tester.getRect(find.byKey(const ValueKey('sg-card')));
    final referenceCard =
        tester.getRect(find.byKey(const ValueKey('reference-card')));
    final sgTitle = tester.getRect(find.text('SG-Node'));
    final referenceTitle = tester.getRect(find.text('参考标题'));
    final sgStatus = tester.getRect(find.descendant(
      of: find.byType(SgNodeStatusTile),
      matching: find.byType(Text),
    ).last);
    final referenceStatus = tester.getRect(find.text('参考状态'));

    // Keep the reference geometry visible in CI until the first green run.
    // ignore: avoid_print
    print('SG geometry: card=$sgCard title=$sgTitle status=$sgStatus; '
        'reference: card=$referenceCard title=$referenceTitle '
        'status=$referenceStatus');

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
