import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('setup prepares the SG overlay even when no user script is active', () {
    final source = File('lib/state.dart').readAsStringSync();
    final setup = source.indexOf(
      'scriptedConfig: await _writePreparedConfig(',
    );
    final disabledFastPath = source.indexOf(
      'if (!scriptActive && !settings.enabled)',
    );
    final firstOverlay = source.indexOf(
      'final trustedCorplinkNames = await applyCorplinkSgNode(',
    );
    final script = source.indexOf(
      'await JavaScriptRuntimeManager.evaluateScriptFile(',
      firstOverlay,
    );
    final secondOverlay = source.indexOf(
      'await applyCorplinkSgNode(',
      script,
    );

    expect(setup, greaterThanOrEqualTo(0));
    expect(disabledFastPath, greaterThan(setup));
    expect(firstOverlay, greaterThan(disabledFastPath));
    expect(script, greaterThan(firstOverlay));
    expect(secondOverlay, greaterThan(script));
    expect(
      source,
      contains('suppressCorplinkNode: suppressCorplinkNode'),
    );
  });
}
