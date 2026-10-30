// Bettbox 服务分流 v1：远程 rule-provider，保留应用生成的 CorpLink 节点。
// 飞连配置中关闭既有 ChatGPT/OpenAI 自动规则；本脚本负责服务分流。
// 来源与部署说明：docs/07-远程覆写与服务分流.md。
// 按上游节点的 server 字段排除；[] 关闭。true 为精确匹配，false 为包含匹配。
const DELETED_SERVERS = ['127.0.0.1', '0.0.0.0'];
const SERVER_STRICT_MODE = true;

// 上游节点名称包含任一关键词即移除，忽略英文大小写；[] 关闭过滤。
// 按字面子串匹配，不是正则表达式。飞连管理的 WG 节点不参与过滤。
const DELETED_NAME_KEYWORDS = ['IPV6专用', '剩余', '到期'];

function main(config) {
  'use strict';
  // 先过滤，再从剩余节点生成服务组；provider 更新时由内核继续过滤。
  const keywords = DELETED_NAME_KEYWORDS.filter(k => typeof k === 'string' && k.trim());
  const blocked = name => typeof name === 'string' && keywords.some(k => name.toLowerCase().includes(k.toLowerCase()));
  const deletedServers = DELETED_SERVERS.filter(s => typeof s === 'string' && s.trim());
  const blockedServer = server => typeof server === 'string' && server.length > 0 &&
    (SERVER_STRICT_MODE ? deletedServers.includes(server) : deletedServers.some(s => server.includes(s)));
  const removed = new Set();
  if (Array.isArray(config.proxies)) config.proxies = config.proxies.filter(p => {
    if (!p.corplink && (blocked(p.name) || blockedServer(p.server))) { removed.add(p.name); return false; }
    return true;
  });
  const originalGroups = Array.isArray(config['proxy-groups']) ? config['proxy-groups'] : [];
  const groupNames = new Set(originalGroups.map(g => g.name));
  const protectedNodes = new Set((config.proxies || []).filter(p => p.corplink).map(p => p.name));
  const unavailable = name => removed.has(name) ||
    (!groupNames.has(name) && !protectedNodes.has(name) && blocked(name));
  for (const g of originalGroups) {
    if (Array.isArray(g.proxies)) {
      const before = g.proxies.length;
      g.proxies = g.proxies.filter(name => !unavailable(name));
      if (before && !g.proxies.length && !(g.use || []).length && !g['include-all'] && !g['include-all-proxies'] && !g['include-all-providers']) {
        g.proxies = ['REJECT'];
      }
    }
    if (keywords.length && ((g.use || []).length || g['include-all'] || g['include-all-providers'])) {
      if (!g['empty-fallback']) g['empty-fallback'] = 'REJECT';
    }
  }
  const nodeFilters = {};
  const oldFilters = (config['bettbox-service-routing'] || {}).nodeFilters || {};
  // Mihomo 用反引号分隔多个 exclude-filter 正则；转义关键词里的分隔符。
  const keywordPattern = keywords.length ? '(?i)' + keywords.map(k =>
    k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/`/g, '\\x60')).join('|') : '';
  for (const [name, provider] of Object.entries(config['proxy-providers'] || {})) {
    if (unavailable(provider['dialer-proxy'])) provider['dialer-proxy'] = 'REJECT';
    let original = provider['exclude-filter'];
    if (oldFilters[name] && original === oldFilters[name].applied) original = oldFilters[name].original;
    if (keywordPattern) {
      const applied = original ? original + '`' + keywordPattern : keywordPattern;
      provider['exclude-filter'] = applied;
      nodeFilters[name] = { original, applied };
    } else if (original === undefined) delete provider['exclude-filter'];
    else provider['exclude-filter'] = original;
  }
  for (const p of config.proxies || []) {
    if (unavailable(p['dialer-proxy'])) p['dialer-proxy'] = 'REJECT';
  }
  for (const field of ['rules', 'rule']) if (Array.isArray(config[field])) {
    config[field] = config[field].map(rule => {
      if (typeof rule !== 'string') return rule;
      const parts = rule.split(',');
      const target = parts.length - (parts[parts.length - 1] === 'no-resolve' ? 2 : 1);
      if (target > 0 && unavailable(parts[target])) parts[target] = 'REJECT';
      return parts.join(',');
    });
  }
  const base = 'http://172.18.34.110:44468';
  const names = ['OpenAI 服务', 'Google 服务', 'OpenAI 服务 · 订阅',
    'Google 服务 · 韩国', 'Google 服务 · 其他'];
  const marker = 'bettbox-service-routing';
  const previous = config[marker];
  const owned = previous && previous.version === 1 ? previous.groups || [] : [];
  const proxies = Array.isArray(config.proxies) ? config.proxies : [];
  const groups = Array.isArray(config['proxy-groups']) ? config['proxy-groups'] : [];
  for (const item of [...proxies, ...groups]) {
    if (names.includes(item.name) && !owned.includes(item.name)) {
      throw new Error('SERVICE_GROUP_NAME_COLLISION: ' + item.name);
    }
  }
  const existingGroups = groups.filter(g => !owned.includes(g.name));
  // 仅认可实际存在、由应用生成的单 WG 成员组，不能将订阅同名组当成飞连。
  function managedGroup(pattern) {
    return existingGroups.find(g => pattern.test(g.name) &&
      Array.isArray(g.proxies) && g.proxies.length === 1 &&
      proxies.some(p => p.name === g.proxies[0] && p.type === 'wireguard' && p.corplink));
  }
  const intl = managedGroup(/^(?:FZ-INT-Node|FUZHOU_INTL_node|INTL[-_]node)$/i);
  const corporate = managedGroup(/^Fuzhou-Node-1$/i);

  // 保守地区白名单：两服务官方支持清单的常用交集，2026-10-30 核验。
  // 国家码必须独立或后跟节点编号；不把 BUSINESS / AUSome 识别为 US。
  const regions = [
    ['KR', '🇰🇷|韩国|韓國|首尔|首爾|South[ _-]?Korea|Seoul'],
    ['JP', '🇯🇵|日本|东京|東京|大阪|Japan|Tokyo|Osaka'],
    ['SG', '🇸🇬|新加坡|狮城|獅城|Singapore'],
    ['TW', '🇹🇼|台湾|台灣|台北|Taiwan|Taipei'],
    ['US', '🇺🇸|美国|美國|洛杉矶|洛杉磯|硅谷|纽约|紐約|United[ _-]?States|Los[ _-]?Angeles'],
    ['CA', '🇨🇦|加拿大|Canada|Toronto|Vancouver'],
    ['GB', '🇬🇧|英国|英國|United[ _-]?Kingdom|Britain|London'],
    ['DE', '🇩🇪|德国|德國|Germany|Frankfurt'],
    ['FR', '🇫🇷|法国|法國|France|Paris'],
    ['NL', '🇳🇱|荷兰|荷蘭|Netherlands|Amsterdam'],
    ['AU', '🇦🇺|澳大利亚|澳大利亞|澳洲|Australia|Sydney'],
    ['NZ', '🇳🇿|新西兰|紐西蘭|New[ _-]?Zealand'],
    ['IN', '🇮🇳|印度(?!尼)|India(?![A-Za-z])'], ['ID', '🇮🇩|印尼|印度尼西亚|Indonesia'],
    ['MY', '🇲🇾|马来西亚|馬來西亞|Malaysia'], ['TH', '🇹🇭|泰国|泰國|Thailand'],
    ['VN', '🇻🇳|越南|Vietnam'], ['PH', '🇵🇭|菲律宾|菲律賓|Philippines'],
    ['BR', '🇧🇷|巴西|Brazil'], ['MX', '🇲🇽|墨西哥|Mexico'],
    ['AR', '🇦🇷|阿根廷|Argentina'], ['CL', '🇨🇱|智利|Chile'],
    ['TR', '🇹🇷|土耳其|Türkiye|Turkey'], ['ES', '🇪🇸|西班牙|Spain'],
    ['IT', '🇮🇹|意大利|義大利|Italy'], ['CH', '🇨🇭|瑞士|Switzerland'],
    ['SE', '🇸🇪|瑞典|Sweden'], ['FI', '🇫🇮|芬兰|芬蘭|Finland'],
    ['NO', '🇳🇴|挪威|Norway'], ['IE', '🇮🇪|爱尔兰|愛爾蘭|Ireland'],
  ];
  const code = c => '(?:^|[^A-Za-z])' + c + '(?:[0-9]+|$|[^A-Za-z])';
  const expressions = regions.map(([c, text]) => [c, '(?:' + text.split('|').map(alias =>
    /^[A-Za-z]/.test(alias) ? '(?:^|[^A-Za-z])(?:' + alias + ')(?:$|[^A-Za-z])' : alias
  ).join('|') + '|' + code(c) + ')']);
  const flags = regions.map(([, text]) => text.split('|')[0]);
  const unknownFlag = '(?!(?:' + flags.join('|') + '))[🇦-🇿]{2}';
  const rejected = '🇭🇰|🇲🇴|🇨🇳|🇷🇺|香港|澳门|澳門|中国大陆|中國大陸|俄罗斯|俄羅斯|' +
    'Hong[ _-]?Kong|Macau|Macao|China|Russia|' + code('HK') + '|' + code('MO') + '|' + code('CN') + '|' + code('RU') +
    '|DIRECT|REJECT|COMPATIBLE|剩余|剩餘|流量|到期|有效期|回国|回國|官网|官網|套餐|' + unknownFlag;
  const bad = new RegExp(rejected, 'iu');
  function country(name) {
    if (bad.test(name)) return null;
    const matches = expressions.filter(([, pattern]) => new RegExp(pattern, 'iu').test(name));
    return matches.length === 1 ? matches[0][0] : null;
  }
  const supported = [];
  const korean = [];
  const others = [];
  for (const p of proxies) {
    if (typeof p.name !== 'string' || p.corplink ||
        /^(?:direct|reject|reject-?drop|pass|pass-?rule|dns|compatible)$/i.test(p.type || '')) continue;
    const region = country(p.name);
    if (!region) continue;
    supported.push(p.name);
    (region === 'KR' ? korean : others).push(p.name);
  }
  const providers = Object.keys(config['proxy-providers'] || {});
  if (!intl && supported.length === 0 && providers.length === 0) {
    throw new Error('NO_SUPPORTED_SERVICE_NODE: 请勾选 INT 节点或提供可识别支持地区的订阅节点');
  }
  const unique = values => [...new Set(values)];
  const added = [];
  function fallback(name, members, url, status, extra) {
    const g = Object.assign({ name, type: 'fallback', proxies: unique(members),
      url, 'expected-status': status, interval: 60, timeout: 5000, lazy: false,
      'max-failed-times': 1, 'empty-fallback': 'REJECT' }, extra || {});
    added.push(g);
    return name;
  }
  const probeUrls = new Set([
    ...Object.values(config['proxy-providers'] || {}).map(p => (p['health-check'] || {}).url),
    ...existingGroups.map(g => g.url),
  ]);
  function isolatedProbe(baseUrl, service) {
    const first = baseUrl + '?bettbox-health=' + service + '-v1';
    let url = first;
    for (let i = 2; probeUrls.has(url); i++) url = first + '-' + i;
    return url;
  }
  const openaiProbe = isolatedProbe('https://chatgpt.com/cdn-cgi/trace', 'openai');
  const googleProbe = isolatedProbe('https://www.google.com/generate_204', 'google');
  let openaiMembers = [...(intl ? [intl.name] : []), ...supported];
  let googleMembers = [...korean, ...others, ...(intl ? [intl.name] : [])];
  if (providers.length) {
    // proxy-provider 内容在运行期才加载，以单独层级保证韩国优先和 INT 最后。
    // 多地区冲突名称在运行期通过 exclude-filter 排除。表达式兼容 Mihomo regexp2。
    const all = expressions.map(([, p]) => p).join('|');
    const kr = expressions[0][1];
    const rest = expressions.slice(1).map(([, p]) => p).join('|');
    const conflicts = expressions.map(([, p], i) =>
      '(?=.*(?:' + p + '))(?=.*(?:' + expressions.filter((_, j) => j !== i).map(([, other]) => other).join('|') + '))'
    ).join('|');
    const exclude = '(?i)' + rejected + '|' + conflicts;
    const excludedTypes = 'Direct|Reject|RejectDrop|Compatible|Pass|PassRule|Dns';
    const openaiTier = fallback(names[2], supported, openaiProbe, '200',
      { use: providers, filter: '(?i)' + all, 'exclude-filter': exclude, 'exclude-type': excludedTypes, hidden: true });
    const koreanTier = fallback(names[3], korean, googleProbe, '204',
      { use: providers, filter: '(?i)' + kr, 'exclude-filter': exclude, 'exclude-type': excludedTypes, hidden: true });
    const otherTier = fallback(names[4], others, googleProbe, '204',
      { use: providers, filter: '(?i)' + rest, 'exclude-filter': exclude, 'exclude-type': excludedTypes, hidden: true });
    openaiMembers = [...(intl ? [intl.name] : []), openaiTier];
    googleMembers = [koreanTier, otherTier, ...(intl ? [intl.name] : [])];
  }
  fallback(names[0], openaiMembers, openaiProbe, '200');
  fallback(names[1], googleMembers, googleProbe, '204');

  const rules = [];
  const ruleProviders = Object.assign({}, config['rule-providers'] || {});
  const ownedProviders = previous && Array.isArray(previous.providers) ? previous.providers : [];
  for (const name of ownedProviders) delete ruleProviders[name];
  const providerNames = [];
  function remote(key, file, target, noResolve) {
    const name = 'bettbox-' + key;
    if (Object.prototype.hasOwnProperty.call(ruleProviders, name)) {
      throw new Error('SERVICE_PROVIDER_NAME_COLLISION: ' + name);
    }
    ruleProviders[name] = { type: 'http', behavior: 'classical', format: 'yaml',
      url: base + '/' + file + '.yaml',
      path: './rule-providers/' + name + '.yaml', interval: 86400, proxy: 'DIRECT' };
    // 发布器从同份远程规则生成快照，仅在无下载缓存时保护首启分流。
    // 正常更新始终使用 HTTP 文件；不在代码中维护另一份域名清单。
    if (typeof BETTBOX_RULE_SNAPSHOT !== 'undefined' && BETTBOX_RULE_SNAPSHOT[key]) {
      ruleProviders[name].payload = BETTBOX_RULE_SNAPSHOT[key];
    }
    providerNames.push(name);
    rules.push('RULE-SET,' + name + ',' + target + (noResolve ? ',no-resolve' : ''));
  }
  rules.push('IP-CIDR,172.18.34.110/32,DIRECT,no-resolve');
  // 保留旧脚本的设备绕过和企业路由，随远程脚本分发；不新建服务端规则文件。
  const local = typeof BETTBOX_LOCAL_ROUTING !== 'undefined' ? BETTBOX_LOCAL_ROUTING : {};
  function route(raw, target) {
    const parts = raw.split(',');
    return [parts[0], parts[1], target, ...parts.slice(2).filter(Boolean)].join(',');
  }
  for (const raw of local.bypass || []) rules.push(route(raw, 'DIRECT'));
  if (corporate) for (const raw of local.corporate || []) rules.push(route(raw, corporate.name));
  remote('openai', 'padavan_openai_domains', names[0], false);
  remote('google', 'google_proxy_domains', names[1], false);
  if (intl) remote('overseas', 'sg-node-overseas-no-google', intl.name, false);
  const ownedRule = rule => typeof rule === 'string' &&
    previous && Array.isArray(previous.rules) && previous.rules.includes(rule);
  const oldRules = Array.isArray(config.rules) ? config.rules : (Array.isArray(config.rule) ? config.rule : []);
  const retained = oldRules.filter(r => !ownedRule(r));
  if (!retained.some(r => typeof r === 'string' && /^(?:MATCH|FINAL),/.test(r))) retained.push('MATCH,DIRECT');
  config.rules = unique([...rules, ...retained]);
  delete config.rule;
  config['rule-providers'] = ruleProviders;
  config['proxy-groups'] = [...existingGroups, ...added];
  const dns = Object.assign({}, config.dns || {});
  dns.enable = true;
  dns['nameserver-policy'] = Object.assign({
    'rule-set:bettbox-openai': ['https://1.1.1.1/dns-query#' + names[0]],
    'rule-set:bettbox-google': ['https://1.1.1.1/dns-query#' + names[1]],
  }, dns['nameserver-policy'] || {});
  // 幂等时以本脚本的服务绑定为准，其他 DNS 策略保留。
  dns['nameserver-policy']['rule-set:bettbox-openai'] = ['https://1.1.1.1/dns-query#' + names[0]];
  dns['nameserver-policy']['rule-set:bettbox-google'] = ['https://1.1.1.1/dns-query#' + names[1]];
  if (!Array.isArray(dns.nameserver) || !dns.nameserver.length) {
    dns.nameserver = ['https://1.1.1.1/dns-query#' + names[1]];
  }
  if (!Array.isArray(dns['proxy-server-nameserver']) || !dns['proxy-server-nameserver'].length) {
    // 代理服务器本身的域名引导不能再次依赖同一代理组。
    dns['proxy-server-nameserver'] = ['system'];
  }
  config.dns = dns;
  config[marker] = { version: 1, groups: added.map(g => g.name), providers: providerNames, rules };
  if (Object.keys(nodeFilters).length) config[marker].nodeFilters = nodeFilters;
  return config;
}
