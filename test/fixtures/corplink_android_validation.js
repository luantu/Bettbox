// Emulator-only validation; remove this script after the test.
function main(config) {
  const groups = Array.isArray(config['proxy-groups']) ? config['proxy-groups'] : [];
  const fuzhou = groups.find((group) => group.name === 'Fuzhou-Node-1');
  const probeHost = typeof fuzhou?.url === 'string'
    ? fuzhou.url.match(/^https:\/\/([^/:?#]+)/)?.[1]
    : null;
  if (!probeHost) throw new Error('FUZHOU_PROBE_NOT_CONFIGURED');

  config['rule-providers'] = config['rule-providers'] || {};
  config['rule-providers']['codex-fuzhou-validation'] = {
    type: 'inline', behavior: 'domain', payload: [probeHost],
  };
  const rule = 'RULE-SET,codex-fuzhou-validation,Fuzhou-Node-1';
  config.rules = [rule, ...(Array.isArray(config.rules) ? config.rules : []).filter((item) => item !== rule)];

  const names = ['codex-direct-validation', 'codex-intl-validation', 'codex-fuzhou-validation'];
  config.listeners = [
    ...(Array.isArray(config.listeners) ? config.listeners : []).filter((item) => !names.includes(item.name)),
    { name: names[0], type: 'mixed', listen: '127.0.0.1', port: 17890, proxy: 'DIRECT' },
    { name: names[1], type: 'mixed', listen: '127.0.0.1', port: 17891, proxy: 'FZ-INT-Node' },
    { name: names[2], type: 'mixed', listen: '127.0.0.1', port: 17892, proxy: 'Fuzhou-Node-1' },
  ];
  return config;
}
