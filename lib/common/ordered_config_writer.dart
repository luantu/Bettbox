import 'dart:async';

/// Serializes the whole write, including encoding and the preference mirror.
/// Atomic rename alone cannot prevent an older async save from landing last.
class OrderedConfigWriter<T> {
  OrderedConfigWriter(this._write);
  final Future<bool> Function(T snapshot) _write;
  Future<void> _tail = Future<void>.value();

  Future<bool> save(T snapshot) {
    final result = Completer<bool>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await _write(snapshot));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}
