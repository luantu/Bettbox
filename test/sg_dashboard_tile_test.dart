import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('existing Android layout gains SG tile once before the start button', () {
    final original = [
      DashboardWidget.networkSpeed,
      DashboardWidget.startButton,
    ];
    final migrated = insertDefaultSgTile(original);
    expect(migrated, [
      DashboardWidget.networkSpeed,
      DashboardWidget.sgNode,
      DashboardWidget.startButton,
    ]);
    expect(insertDefaultSgTile(migrated), migrated);
    expect(original, [DashboardWidget.networkSpeed, DashboardWidget.startButton]);
  });

  test('SG tile choice survives saved dashboard JSON', () {
    const settings = AppSettingProps(
      mobileDashboardWidgets: [DashboardWidget.sgNode, DashboardWidget.startButton],
    );
    final restored = AppSettingProps.fromJson(settings.toJson());
    expect(restored.mobileDashboardWidgets,
        [DashboardWidget.sgNode, DashboardWidget.startButton]);
    expect(settings.toJson()['mobileDashboardWidgets'], ['sgNode', 'startButton']);
  });
}
