/// A local profile keeps the Mihomo setup path available before the user adds
/// an airport subscription. It contains no credential or CorpLink endpoint.
const sgBootstrapProfileId = 'bettbox-sg-bootstrap';

const sgBootstrapProfileYaml = '''
mode: rule
proxies: []
proxy-groups:
  - name: BASE
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,BASE
''';

String selectProfileAfterImport(String? currentId, String importedId) {
  if (currentId == null || currentId == sgBootstrapProfileId) {
    return importedId;
  }
  return currentId;
}
