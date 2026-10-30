package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

// Exercise the shipped JavaScript against the actual Mihomo parser, including
// regexp2 provider filtering and first-download failure with seeded rules.
func TestServiceRoutingScriptProviderFilteringAndColdRules(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node is required for the script integration test")
	}
	program := `
const fs = require('fs'), vm = require('vm');
const ctx = vm.createContext({BETTBOX_RULE_SNAPSHOT:{openai:['DOMAIN-SUFFIX,chatgpt.com'],google:['DOMAIN-SUFFIX,google.com']}});
vm.runInContext(fs.readFileSync('../scripts/overrides/overwrite-bettbox.js','utf8'),ctx);
const leaf = name => ({name,type:'socks5',server:'127.0.0.1',port:9});
const c = ctx.main({'proxies':[leaf('JP01')], 'proxy-providers':{subscription:{type:'inline',payload:[leaf('KR01'),leaf('HK01'),leaf('US01'),leaf('US-KR 1'),
  {name:'韩国零号',type:'direct'}, {name:'日本零号',type:'dns'}, {name:'美国零号',type:'reject'}, leaf('🇰🇵 Korea Seoul'),leaf('SouthAmerica 01')]}}});
process.stdout.write(JSON.stringify(c));`
	data, err := exec.Command("node", "-e", program).CombinedOutput()
	if err != nil {
		t.Fatalf("script failed: %v: %s", err, data)
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	previousHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	defer C.SetHomeDir(previousHome)
	var available atomic.Bool
	var requests atomic.Int32
	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if available.Load() {
			_, _ = w.Write([]byte("payload:\n  - DOMAIN-SUFFIX,downloaded.example\n"))
			return
		}
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
	}))
	defer failing.Close()
	for name, p := range raw.RuleProvider {
		p["url"] = failing.URL + "/" + name
		p["path"] = filepath.Join(C.Path.HomeDir(), name+".yaml")
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string][]string{
		"Google 服务 · 韩国": {"KR01"},
		"Google 服务 · 其他": {"JP01", "US01"},
		"OpenAI 服务 · 订阅": {"JP01", "KR01", "US01"},
	} {
		p := parsed.Proxies[name]
		bytes, err := p.MarshalJSON()
		if err != nil {
			t.Fatal(err)
		}
		var group struct {
			All []string `json:"all"`
		}
		if err := json.Unmarshal(bytes, &group); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(group.All, want) {
			t.Fatalf("%s candidates: got %v, want %v", name, group.All, want)
		}
	}
	for name, host := range map[string]string{"bettbox-openai": "chatgpt.com", "bettbox-google": "google.com"} {
		provider := parsed.RuleProviders[name]
		if err := provider.Initial(); err == nil {
			t.Fatalf("%s unexpectedly downloaded from a failing server", name)
		}
		if provider.Count() == 0 || !provider.Match(&C.Metadata{Host: host}, C.RuleMatchHelper{}) {
			t.Fatalf("%s lost its service rules on first download failure", name)
		}
		available.Store(true)
		if err := provider.Update(); err != nil {
			t.Fatalf("%s could not load its HTTP rules: %v", name, err)
		}
		if !provider.Match(&C.Metadata{Host: "downloaded.example"}, C.RuleMatchHelper{}) {
			t.Fatalf("%s ignored its downloaded rules", name)
		}
		available.Store(false)
		if err := provider.Update(); err == nil {
			t.Fatalf("%s unexpectedly updated from a failing server", name)
		}
		if !provider.Match(&C.Metadata{Host: "downloaded.example"}, C.RuleMatchHelper{}) {
			t.Fatalf("%s lost downloaded rules after update failure", name)
		}
	}
	if requests.Load() < 6 {
		t.Fatal("HTTP download scenarios were not actually exercised")
	}
}

// Only the TCP endpoint is replaced: actual Proxy.URLTest, HTTP status handling,
// provider health tasks and fallback selection all execute production code.
type serviceProbeEndpoint struct {
	C.ProxyAdapter
	name, address string
}

func (p *serviceProbeEndpoint) Name() string        { return p.name }
func (p *serviceProbeEndpoint) Type() C.AdapterType { return C.Socks5 }
func (p *serviceProbeEndpoint) DialContext(ctx context.Context, _ *C.Metadata) (C.Conn, error) {
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", p.address)
	if err != nil {
		return nil, err
	}
	return outbound.NewConn(c, p), nil
}

func TestServiceProbe403DoesNotMaskHealthyFallback(t *testing.T) {
	for _, status := range []int{200, 204} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403) }))
			defer bad.Close()
			good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
			defer good.Close()
			proxies := []C.Proxy{
				adapter.NewProxy(&serviceProbeEndpoint{outbound.NewDirect(), "KR01", bad.Listener.Addr().String()}),
				adapter.NewProxy(&serviceProbeEndpoint{outbound.NewDirect(), "US01", good.Listener.Addr().String()}),
			}
			broadURL := "http://service.invalid/probe"
			serviceURL := broadURL + "?bettbox-health=isolated"
			broad, _ := utils.NewUnsignedRanges[uint16]("200-499")
			strict, _ := utils.NewUnsignedRanges[uint16](strconv.Itoa(status))
			hc := provider.NewHealthCheck(proxies, broadURL, 1000, 0, false, broad)
			pd, err := provider.NewCompatibleProvider("probe-provider", proxies, hc)
			if err != nil {
				t.Fatal(err)
			}
			defer pd.Close()
			pd.RegisterHealthCheckTask(serviceURL, strict, "", 0)
			pd.HealthCheck()
			if !proxies[0].AliveForTestUrl(broadURL) || proxies[0].AliveForTestUrl(serviceURL) {
				t.Fatal("403 was not isolated from the permissive provider probe")
			}
			g, err := outboundgroup.NewFallback(outboundgroup.GroupCommonOption{Name: "service", URL: serviceURL}, outboundgroup.FallbackOption{}, adapter.NewProxy(outbound.NewReject()), []P.ProxyProvider{pd})
			if err != nil {
				t.Fatal(err)
			}
			if g.Now() != "US01" {
				t.Fatalf("selected %s instead of the healthy fallback", g.Now())
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, _ = proxies[0].URLTest(ctx, broadURL, broad)
			if g.Now() != "US01" {
				t.Fatal("a later permissive provider probe poisoned service selection")
			}
		})
	}
}
