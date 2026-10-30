"""Build the remotely distributed script using rule files as its single source."""
import json
import ipaddress
from pathlib import Path
import sys
import yaml


def build(rule_dir, output):
    snapshots = {}
    for name, filename in (('openai', 'padavan_openai_domains.yaml'), ('google', 'google_proxy_domains.yaml')):
        payload = yaml.safe_load((rule_dir / filename).read_text())['payload']
        if not isinstance(payload, list) or not payload or any(not isinstance(x, str) for x in payload):
            raise ValueError('Invalid or empty rule payload: ' + name)
        if any(x in ('MATCH', 'FINAL') or x.startswith(('MATCH,', 'FINAL,')) for x in payload):
            raise ValueError('Catch-all is not allowed in service rule payload: ' + name)
        snapshots[name] = payload
    local_path = rule_dir / 'local-routing.json'
    local = json.loads(local_path.read_text())
    if not isinstance(local, dict) or set(local) != {'bypass', 'corporate'}:
        raise ValueError('local-routing.json must contain bypass and corporate')
    for name, payload in local.items():
        if not isinstance(payload, list) or not payload:
            raise ValueError('Local routing must not be empty: ' + name)
        for rule in payload:
            if not isinstance(rule, str):
                raise ValueError('Local rule must be a string: ' + name)
            parts = rule.split(',')
            if len(parts) not in (2, 3) or not parts[1] or (len(parts) == 3 and parts[2] != 'no-resolve'):
                raise ValueError('Invalid local rule fields: ' + name)
            if parts[0] in ('IP-CIDR', 'IP-CIDR6'):
                net = ipaddress.ip_network(parts[1])
                if net.prefixlen == 0 or (parts[0] == 'IP-CIDR6') != (net.version == 6):
                    raise ValueError('Default route or address family mismatch: ' + name)
            elif parts[0] not in ('DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD') or len(parts) != 2:
                raise ValueError('Unsupported local rule type: ' + name)
    source = Path(__file__).with_name('overwrite-bettbox.js').read_text()
    content = '// 自动生成：规则来源为同目录 HTTP YAML，包含首启应急快照。\n' + \
        'const BETTBOX_RULE_SNAPSHOT = ' + json.dumps(snapshots, ensure_ascii=False, separators=(',', ':')) + ';\n' + \
        'const BETTBOX_LOCAL_ROUTING = ' + json.dumps(local, ensure_ascii=False, separators=(',', ':')) + ';\n' + source
    output.write_text(content)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: build_service_bundle.py RULE_DIRECTORY OUTPUT_JS')
    build(Path(sys.argv[1]), Path(sys.argv[2]))
