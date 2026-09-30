import 'package:bett_box/models/models.dart';

/// A managed CorpLink node has one WireGuard outbound in its exact-name group.
/// Its configured HTTPS probe must not be replaced by the app-wide delay URL.
String resolveCorplinkDelayUrl({
  required String proxyName,
  required String preferredUrl,
  required String ordinaryUrl,
  required Iterable<Group> groups,
}) {
  if (preferredUrl.isEmpty || !proxyName.endsWith('-WG')) {
    return ordinaryUrl;
  }
  final serverName = proxyName.substring(0, proxyName.length - 3);
  for (final group in groups) {
    if (group.name != serverName ||
        group.testUrl == null ||
        group.testUrl!.isEmpty ||
        group.all.length != 1) {
      continue;
    }
    final outbound = group.all.single;
    if (outbound.name == proxyName &&
        outbound.type.toLowerCase() == 'wireguard') {
      return preferredUrl;
    }
  }
  return ordinaryUrl;
}
