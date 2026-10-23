import 'dart:typed_data';
import 'package:bett_box/plugins/service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('closing a status listener during dispatch cannot break native events', (tester) async {
    final native = Service();
    final delivered = <String>[];
    late NativeEventCallback page;
    final NativeEventCallback manager = (method, arguments) async {
      delivered.add('manager'); native.removeNativeEventCallback(page);
    };
    page = (method, arguments) async { delivered.add('page'); };
    native.addNativeEventCallback(manager); native.addNativeEventCallback(page);
    addTearDown(() {
      native.removeNativeEventCallback(manager); native.removeNativeEventCallback(page);
    });
    const codec = StandardMethodCodec();
    ByteData? envelope;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage('service',
      codec.encodeMethodCall(const MethodCall('networkChanged')),
      (data) => envelope = data);
    expect(envelope, isNotNull);
    expect(() => codec.decodeEnvelope(envelope!), returnsNormally);
    expect(delivered, ['manager', 'page']);
    delivered.clear();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage('service',
      codec.encodeMethodCall(const MethodCall('networkChanged')),
      (_) {});
    expect(delivered, ['manager']);
  });
}
