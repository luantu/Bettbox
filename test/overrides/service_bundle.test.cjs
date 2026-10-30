const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const cp = require('node:child_process');

test('发布包携带从规则文件生成的应急快照，首次离线仍可匹配服务域名', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bettbox-service-rules-'));
  try {
    for (const [name, value] of Object.entries({ padavan_openai_domains: 'DOMAIN-SUFFIX,chatgpt.com', google_proxy_domains: 'DOMAIN-SUFFIX,google.com' }))
      fs.writeFileSync(path.join(dir, name + '.yaml'), 'payload:\n  - ' + value + '\n');
    fs.writeFileSync(path.join(dir, 'local-routing.json'), JSON.stringify({ bypass: ['IP-CIDR,127.0.0.0/8,no-resolve'], corporate: ['DOMAIN-SUFFIX,corp.example'] }));
    const out = path.join(dir, 'bundle.js');
    const build = path.resolve(__dirname, '../../scripts/overrides/build_service_bundle.py');
    assert.equal(fs.existsSync(build), true, '发布器尚未实现');
    cp.execFileSync('python3', [build, dir, out]);
    const ctx = vm.createContext({});
    vm.runInContext(fs.readFileSync(out, 'utf8'), ctx);
    const c = ctx.main({ proxies: [{ name: 'KR01', type: 'ss' }] });
    assert.deepEqual(JSON.parse(JSON.stringify(c['rule-providers']['bettbox-openai'].payload)), ['DOMAIN-SUFFIX,chatgpt.com']);
    assert.deepEqual(JSON.parse(JSON.stringify(c['rule-providers']['bettbox-google'].payload)), ['DOMAIN-SUFFIX,google.com']);
    assert.match(c['rule-providers']['bettbox-openai'].url, /^http:\/\/172\.18\.34\.110:44468\//);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('地理名称印度尼西亚不因包含印度而被错误排除', () => {
  const ctx = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../../scripts/overrides/overwrite-bettbox.js'), 'utf8'), ctx);
  const c = ctx.main({ proxies: [{ name: '🇮🇩 印度尼西亚 01', type: 'ss' }] });
  assert.deepEqual(JSON.parse(JSON.stringify(c['proxy-groups'].find(g => g.name === 'OpenAI 服务').proxies)), ['🇮🇩 印度尼西亚 01']);
});

test('缺少/空白/畸形私有路由时拒绝发布，不静默丢失企业规则', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bettbox-service-publish-'));
  try {
    for (const name of ['padavan_openai_domains', 'google_proxy_domains']) fs.writeFileSync(path.join(dir, name+'.yaml'), 'payload:\n  - DOMAIN-SUFFIX,example.com\n');
    const build = path.resolve(__dirname, '../../scripts/overrides/build_service_bundle.py');
    const run = () => cp.spawnSync('python3', [build, dir, path.join(dir,'bundle.js')], { encoding: 'utf8' });
    assert.notEqual(run().status, 0, '缺文件必须失败');
    for (const payload of [{}, { bypass: [], corporate: [] }, { bypass: ['IP-CIDR,127.0.0.0/8,no-resolve'], corporate: [null] },
      { bypass: ['IP-CIDR,0.0.0.0/0'], corporate: ['DOMAIN-SUFFIX,corp.example'] }]) {
      fs.writeFileSync(path.join(dir,'local-routing.json'), JSON.stringify(payload));
      assert.notEqual(run().status, 0, '错误路由必须失败: '+JSON.stringify(payload));
    }
  } finally { fs.rmSync(dir, {recursive:true,force:true}); }
});
