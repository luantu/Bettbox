import 'dart:async';
import 'package:bett_box/common/ordered_config_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('delayed old save cannot overwrite latest file and preference mirror', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final writes = <String>[];
    var file = ''; var mirror = '';
    final writer = OrderedConfigWriter<String>((snapshot) async {
      if (snapshot == 'old-enabled') {
        firstEntered.complete(); await releaseFirst.future;
      }
      mirror = snapshot; file = snapshot; writes.add(snapshot);
      return true;
    });
    final oldSave = writer.save('old-enabled');
    await firstEntered.future;
    final newSave = writer.save('latest-disabled');
    await Future<void>.delayed(Duration.zero);
    expect(writes, isEmpty);
    releaseFirst.complete();
    expect(await oldSave, isTrue); expect(await newSave, isTrue);
    expect(file, 'latest-disabled'); expect(mirror, 'latest-disabled');
    expect(writes, ['old-enabled', 'latest-disabled']);
  });
  test('a failed save does not poison the queue or report success', () async {
    final writer = OrderedConfigWriter<String>((snapshot) async {
      if (snapshot == 'bad') throw StateError('disk failed');
      return true;
    });
    await expectLater(writer.save('bad'), throwsStateError);
    expect(await writer.save('latest'), isTrue);
  });
}
