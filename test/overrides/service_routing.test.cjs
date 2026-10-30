const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const script = path.join(__dirname, '../../scripts/overrides/overwrite-bettbox.js');

function apply(input, keywords, servers, strictMode) {
  let source = fs.existsSync(script) ? fs.readFileSync(script, 'utf8') : 'function main(c) { return c; }';
  if (strictMode !== undefined) source = source.replace('const SERVER_STRICT_MODE = true;', 'const SERVER_STRICT_MODE = ' + strictMode + ';');
  const ctx = vm.createContext({ BETTBOX_LOCAL_ROUTING: {
    bypass: ['IP-CIDR,127.0.0.0/8,no-resolve'], corporate: ['DOMAIN-SUFFIX,ruijie.work'],
  } });
  vm.runInContext(source, ctx);
  if (keywords) vm.runInContext('DELETED_NAME_KEYWORDS.splice(0, DELETED_NAME_KEYWORDS.length, ...' + JSON.stringify(keywords) + ')', ctx);
  if (servers) vm.runInContext('DELETED_SERVERS.splice(0, DELETED_SERVERS.length, ...' + JSON.stringify(servers) + ')', ctx);
  return JSON.parse(JSON.stringify(ctx.main(JSON.parse(JSON.stringify(input)))));
}
function base() {
  return { proxies: [
    { name: 'FZ-INT-Node-WG', type: 'wireguard', corplink: { managed: true } },
    { name: 'Fuzhou-Node-1-WG', type: 'wireguard', corplink: { managed: true } },
  ], 'proxy-groups': [
    { name: 'FZ-INT-Node', type: 'select', proxies: ['FZ-INT-Node-WG'] },
    { name: 'Fuzhou-Node-1', type: 'select', proxies: ['Fuzhou-Node-1-WG'] },
  ], rules: ['MATCH,DIRECT'] };
}
function group(c, name) { return c['proxy-groups'].find(g => g.name === name); }

test('服务器地址默认精确排除两个占位地址，保留相似地址及飞连WG并清理节点引用', () => {
  const c = base();
  c.proxies[0].server = '127.0.0.1';
  for (const [name, server] of [['KR01','127.0.0.1'],['KR02','0.0.0.0'],['US01','127.0.0.10'],['JP01','edge.127.0.0.1.example']])
    c.proxies.push({name,server,type:'socks5'});
  c['proxy-groups'].push({name:'上游选择',type:'select',proxies:['KR01','US01']},
    {name:'占位组',type:'select',proxies:['KR02']});
  c.rules.unshift('DOMAIN,blocked.example,KR01');
  const out = apply(c);
  assert.deepEqual(out.proxies.map(p => p.name), ['FZ-INT-Node-WG','Fuzhou-Node-1-WG','US01','JP01']);
  assert.deepEqual(group(out,'上游选择').proxies, ['US01']);
  assert.deepEqual(group(out,'占位组').proxies, ['REJECT']);
  assert.ok(out.rules.includes('DOMAIN,blocked.example,REJECT'));
  assert.deepEqual(group(out,'Google 服务').proxies, ['US01','JP01','FZ-INT-Node']);
  assert.deepEqual(apply(out),out);
});

test('非严格服务器模式按字面包含过滤，空地址项不误删，缺失server的节点保留', () => {
  const c = base();
  c.proxies.push({name:'KR01',server:'edge.bad[1].example',type:'socks5'},
    {name:'US01',server:'edge.bad1.example',type:'socks5'}, {name:'JP01',type:'socks5'});
  assert.deepEqual(group(apply(c, undefined, ['bad[1]','','  '], false),'Google 服务').proxies,
    ['US01','JP01','FZ-INT-Node']);
  assert.deepEqual(group(apply(c, undefined, ['bad[1]'], true),'Google 服务').proxies,
    ['KR01','US01','JP01','FZ-INT-Node']);
});

test('清空服务器排除表关闭地址过滤，名称过滤仍独立生效', () => {
  const c = base();
  c.proxies.push({name:'KR01',server:'127.0.0.1',type:'socks5'},
    {name:'JP01 IPV6专用',server:'192.0.2.1',type:'socks5'});
  assert.deepEqual(group(apply(c, undefined, []),'Google 服务').proxies,['KR01','FZ-INT-Node']);
});

test('关键词过滤先于服务组生成，清理原组引用，空组拒绝而不变成直连', () => {
  const c = base();
  c.proxies.push({ name: 'KR01 IPV6专用', type: 'ss' }, { name: 'JP01 ipv6专用', type: 'ss' }, { name: 'US01', type: 'ss' });
  c['proxy-groups'].push(
    { name: '上游选择', type: 'select', proxies: ['KR01 IPV6专用', 'US01'] },
    { name: '上游自动', type: 'url-test', proxies: ['JP01 ipv6专用'], url: 'https://example.com/' },
    { name: 'IPV6专用分组', type: 'select', proxies: ['US01'] },
    { name: '上层', type: 'select', proxies: ['IPV6专用分组'] });
  const out = apply(c);
  assert.deepEqual(out.proxies.map(p => p.name), ['FZ-INT-Node-WG', 'Fuzhou-Node-1-WG', 'US01']);
  assert.deepEqual(group(out, 'Google 服务').proxies, ['US01', 'FZ-INT-Node']);
  assert.deepEqual(group(out, '上游选择').proxies, ['US01']);
  assert.deepEqual(group(out, '上游自动').proxies, ['REJECT']);
  assert.deepEqual(group(out, '上层').proxies, ['IPV6专用分组']);
  assert.deepEqual(apply(out), out);
});

test('关键词可增删，按字面子串匹配，空词不误删全部节点，飞连WG不受影响', () => {
  const c = base();
  c.proxies.push({ name: 'KR01 [测试]', type: 'ss' }, { name: 'US01 测试', type: 'ss' });
  assert.deepEqual(group(apply(c, ['[测试]', '', '  ', 'FZ-INT']), 'Google 服务').proxies, ['US01 测试', 'FZ-INT-Node']);
  c.proxies.push({ name: 'JP01 IPV6专用', type: 'ss' });
  assert.ok(apply(c, []).proxies.some(p => p.name === 'JP01 IPV6专用'));
});

test('动态provider排除关键词，合并原有正则且重复运行不追加相同过滤', () => {
  const c = base();
  c['proxy-providers'] = { airport: { type: 'http', url: 'https://example.com/airport', 'exclude-filter': '(?i)expired' } };
  const out = apply(c);
  const excluded = new RegExp(out['proxy-providers'].airport['exclude-filter'].replace(/\(\?i\)/g, '').replace(/`/g, '|'), 'iu');
  assert.ok(excluded.test('KR01 ipv6专用'));
  assert.ok(excluded.test('US01 Expired'));
  assert.equal(excluded.test('KR01 普通'), false);
  assert.deepEqual(apply(out), out);
  const changed = apply(out, ['测试']);
  assert.equal(changed['proxy-providers'].airport['exclude-filter'], '(?i)expired`(?i)测试');
  assert.equal(apply(changed, [])['proxy-providers'].airport['exclude-filter'], '(?i)expired');
});

test('直接指向被移除节点的规则和链式拨号改为拒绝，避免配置加载失败或意外直连', () => {
  const c = base();
  c.proxies.push({ name: 'KR01 IPV6专用', type: 'ss' },
    { name: 'US01', type: 'socks5', 'dialer-proxy': 'KR01 IPV6专用' });
  c.rules.unshift('DOMAIN,blocked.example,KR01 IPV6专用', 'IP-CIDR,192.0.2.0/24,KR01 IPV6专用,no-resolve');
  const out = apply(c);
  assert.ok(out.rules.includes('DOMAIN,blocked.example,REJECT'));
  assert.ok(out.rules.includes('IP-CIDR,192.0.2.0/24,REJECT,no-resolve'));
  assert.equal(out.proxies.find(p => p.name === 'US01')['dialer-proxy'], 'REJECT');
});

test('无订阅：两服务仅使用 INT，规则来自不同 HTTP providers', () => {
  const c = apply(base());
  assert.deepEqual(group(c, 'OpenAI 服务')?.proxies, ['FZ-INT-Node']);
  assert.deepEqual(group(c, 'Google 服务')?.proxies, ['FZ-INT-Node']);
  assert.equal(group(c, 'OpenAI 服务').type, 'fallback');
  assert.deepEqual(c.rules.slice(0, 6), [
    'IP-CIDR,172.18.34.110/32,DIRECT,no-resolve',
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
    'DOMAIN-SUFFIX,ruijie.work,Fuzhou-Node-1',
    'RULE-SET,bettbox-openai,OpenAI 服务',
    'RULE-SET,bettbox-google,Google 服务',
    'RULE-SET,bettbox-overseas,FZ-INT-Node',
  ]);
  for (const p of Object.values(c['rule-providers'])) {
    assert.match(p.url, /^http:\/\/172\.18\.34\.110:44468\//);
    assert.equal(p.type, 'http');
    assert.equal(p.proxy, 'DIRECT');
  }
  assert.equal(c['rule-providers']['bettbox-openai'].url, 'http://172.18.34.110:44468/padavan_openai_domains.yaml');
  assert.equal(c['rule-providers']['bettbox-google'].url, 'http://172.18.34.110:44468/google_proxy_domains.yaml');
  assert.equal(c['rule-providers']['bettbox-overseas'].url, 'http://172.18.34.110:44468/sg-node-overseas-no-google.yaml');
});

test('订阅：韩国优先，其他支持地区随后，OpenAI 的 INT 最前，Google 的 INT 最后', () => {
  const c = base();
  for (const name of ['🇸🇬 新加坡 01', '🇭🇰 香港', '🇰🇷 韩国 02', 'US01', 'KR01', 'JP-1', '未知线路', '🇨🇳 中国大陆', '🇷🇺 俄罗斯', '剩余流量 12GB', '香港→韩国'])
    c.proxies.push({ name, type: 'ss', server: 'example.com', port: 1 });
  const out = apply(c);
  assert.deepEqual(group(out, 'Google 服务').proxies,
    ['🇰🇷 韩国 02', 'KR01', '🇸🇬 新加坡 01', 'US01', 'JP-1', 'FZ-INT-Node']);
  assert.deepEqual(group(out, 'OpenAI 服务').proxies,
    ['FZ-INT-Node', '🇸🇬 新加坡 01', '🇰🇷 韩国 02', 'US01', 'KR01', 'JP-1']);
});

test('同一节点标两个国家时排除，普通子串不能冒充国家码', () => {
  const c = base();
  for (const name of ['US-KR 1', 'AUSome', 'BUSINESS', 'TOKYO 1', '🇺🇸美国', '美国-日本中转']) c.proxies.push({ name, type: 'ss' });
  assert.deepEqual(group(apply(c), 'Google 服务').proxies, ['TOKYO 1', '🇺🇸美国', 'FZ-INT-Node']);
});

test('保持 SG 对象、原始代理、分组、规则、provider 不变，重复运行幂等', () => {
  const c = base();
  c['rule-providers'] = { existing: { type: 'inline', behavior: 'domain', payload: ['+.example.org'] } };
  c.rules.unshift('DOMAIN,keep.example,DIRECT');
  const snapshot = JSON.parse(JSON.stringify(c));
  const once = apply(c);
  assert.deepEqual(once.proxies, snapshot.proxies);
  assert.deepEqual(once['proxy-groups'].slice(0, 2), snapshot['proxy-groups']);
  assert.deepEqual(once['rule-providers'].existing, snapshot['rule-providers'].existing);
  assert.deepEqual(once.rules.slice(-2), snapshot.rules);
  assert.deepEqual(apply(once), once);
});

test('同名用户组不静默覆盖', () => {
  const c = base();
  c['proxy-groups'].push({ name: 'OpenAI 服务', type: 'select', proxies: ['DIRECT'] });
  assert.throws(() => apply(c), /SERVICE_GROUP_NAME_COLLISION/);
});

test('没有 INT 时支持订阅仍可生成服务组；没有任何候选时明确失败', () => {
  const c = { proxies: [{ name: '韩国01', type: 'ss' }], 'proxy-groups': [] };
  assert.deepEqual(group(apply(c), 'OpenAI 服务').proxies, ['韩国01']);
  assert.throws(() => apply({}), /NO_SUPPORTED_SERVICE_NODE/);
});

test('未勾选福州时不创建企业组或企业引流，保留现有订阅规则', () => {
  const c = base();
  c['proxy-groups'] = c['proxy-groups'].slice(0, 1);
  const out = apply(c);
  assert.equal(out.rules.some(r => r.includes(',Fuzhou-Node-1')), false);
  assert.equal(out['rule-providers']['bettbox-corporate'], undefined);
});

test('DoH 显式绑定服务组，数字 IP 不触发自身域名引导循环', () => {
  const c = base();
  c.dns = { enable: true, 'enhanced-mode': 'fake-ip', 'nameserver-policy': { '+.keep.example': 'system' } };
  const out = apply(c);
  assert.deepEqual(out.dns['nameserver-policy']['rule-set:bettbox-openai'], ['https://1.1.1.1/dns-query#OpenAI 服务']);
  assert.deepEqual(out.dns['nameserver-policy']['rule-set:bettbox-google'], ['https://1.1.1.1/dns-query#Google 服务']);
  assert.equal(out.dns['nameserver-policy']['+.keep.example'], 'system');
  assert.equal(out.dns['enhanced-mode'], 'fake-ip');
});

test('proxy-provider 的韩国层和其他层分别过滤，无匹配时明确拒绝而不直连', () => {
  const c = base();
  c['proxy-providers'] = { subscription: { type: 'http', url: 'https://example.com/provider' } };
  const out = apply(c);
  assert.deepEqual(group(out, 'Google 服务').proxies,
    ['Google 服务 · 韩国', 'Google 服务 · 其他', 'FZ-INT-Node']);
  for (const [tier, good, bad] of [
    ['Google 服务 · 韩国', '🇰🇷 韩国 01', '🇯🇵 日本 01'],
    ['Google 服务 · 其他', '🇯🇵 日本 01', '🇭🇰 香港 01'],
    ['OpenAI 服务 · 订阅', '🇺🇸 美国 01', '🇭🇰 香港 01'],
  ]) {
    const g = group(out, tier);
    assert.deepEqual(g.use, ['subscription']);
    assert.equal(g['empty-fallback'], 'REJECT');
    // Mihomo uses inline flags; JavaScript has the equivalent external flag.
    const filter = new RegExp(g.filter.replace(/^\(\?i\)/, ''), 'iu');
    const excluded = new RegExp(g['exclude-filter'].replace(/^\(\?i\)/, ''), 'iu');
    assert.equal(filter.test(good) && !excluded.test(good), true);
    assert.equal(filter.test(bad) && !excluded.test(bad), false);
  }
});

test('服务探针分开，不允许 403 被当成健康', () => {
  const out = apply(base());
  assert.equal(group(out, 'OpenAI 服务').url, 'https://chatgpt.com/cdn-cgi/trace?bettbox-health=openai-v1');
  assert.equal(group(out, 'OpenAI 服务')['expected-status'], '200');
  assert.equal(group(out, 'Google 服务').url, 'https://www.google.com/generate_204?bettbox-health=google-v1');
  assert.equal(group(out, 'Google 服务')['expected-status'], '204');
});

test('动态层排除伪装为支持地区的直连/DNS类型', () => {
  const c = base();
  c['proxy-providers'] = { airport: { type: 'inline', payload: [] } };
  const out = apply(c);
  for (const name of ['Google 服务 · 韩国', 'Google 服务 · 其他', 'OpenAI 服务 · 订阅']) {
    const excluded = (group(out, name)['exclude-type'] || '').toLowerCase().split('|');
    for (const type of ['direct', 'reject', 'dns', 'compatible', 'pass']) assert.ok(excluded.includes(type));
  }
});

test('原 provider 即使使用宽松同URL探针，也不会污染服务探针状态', () => {
  const c = base();
  c['proxy-providers'] = {
    airport: { type: 'http', 'health-check': { url: 'https://chatgpt.com/cdn-cgi/trace?bettbox-health=openai-v1', 'expected-status': '200-499' } },
    other: { type: 'http', 'health-check': { url: 'https://chatgpt.com/cdn-cgi/trace', 'expected-status': '200-499' } },
  };
  const out = apply(c);
  assert.notEqual(group(out, 'OpenAI 服务').url, c['proxy-providers'].airport['health-check'].url);
  assert.notEqual(group(out, 'OpenAI 服务').url, c['proxy-providers'].other['health-check'].url);
  assert.equal(out['proxy-providers'].airport['health-check'].url, c['proxy-providers'].airport['health-check'].url);
  assert.deepEqual(out['proxy-providers'].other['health-check'], c['proxy-providers'].other['health-check']);
  assert.deepEqual(apply(out), out);
});

test('未标记的同名前缀用户规则保留，同名provider明确拒绝覆盖', () => {
  const c = base();
  c['rule-providers'] = { 'bettbox-private': { type: 'inline', behavior: 'domain', payload: ['+.private.example'] } };
  c.rules.unshift('RULE-SET,bettbox-private,DIRECT');
  assert.ok(apply(c).rules.includes('RULE-SET,bettbox-private,DIRECT'));
  c['rule-providers']['bettbox-google'] = { type: 'inline', behavior: 'domain', payload: ['+.keep.example'] };
  assert.throws(() => apply(c), /SERVICE_PROVIDER_NAME_COLLISION/);
});

test('地区白名单拒绝SouthAmerica和未知/冲突国旗', () => {
  const c = base();
  for (const name of ['SouthAmerica 01', '🇰🇵 Korea Seoul', '🇺🇸🇰🇵 US01', '🇸🇬 Singapore 01']) c.proxies.push({ name, type: 'ss' });
  assert.deepEqual(group(apply(c), 'Google 服务').proxies, ['🇸🇬 Singapore 01', 'FZ-INT-Node']);
});
