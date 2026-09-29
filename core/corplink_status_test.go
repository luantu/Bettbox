package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
)

type statusProxy struct {
	C.Proxy
	adapter C.ProxyAdapter
}

func (p statusProxy) Adapter() C.ProxyAdapter { return p.adapter }

type statusAdapter struct {
	outbound.ProxyAdapter
	status     outbound.CorplinkStatus
	serverName string
	reconnects int
	rebuilds   int
}

func (a *statusAdapter) CorplinkStatus() outbound.CorplinkStatus { return a.status }
func (a *statusAdapter) CorplinkServerName() string              { return a.serverName }
func (a *statusAdapter) Reconnect()                              { a.reconnects++ }
func (a *statusAdapter) RebuildCorplink(context.Context) error   { a.rebuilds++; return nil }
func (a *statusAdapter) Name() string                            { return "test" }
func (a *statusAdapter) Close() error                            { return nil }

func TestCorplinkStatusReportsMissingAndReadyNodes(t *testing.T) {
	missing := corplinkStatusFromProxies(nil)
	if missing.Present || missing.Ready {
		t.Fatalf("missing node reported active: %+v", missing)
	}
	want := outbound.CorplinkStatus{Initialized: true, Ready: true, TunnelIP: "10.0.0.2/32"}
	proxy := statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(&statusAdapter{status: want})}
	got := corplinkStatusFromProxies(map[string]C.Proxy{"SG-Node": proxy})
	if !got.Present || !got.Ready || got.TunnelIP != want.TunnelIP {
		t.Fatalf("status lost across core boundary: %+v", got)
	}
	data, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"tunnelIp":"10.0.0.2/32"`) ||
		strings.Contains(string(data), "privateKey") ||
		strings.Contains(string(data), "cookie") {
		t.Fatalf("invalid or unsafe status JSON: %s", data)
	}
}

func TestCorplinkNodeStatusesAreIndependent(t *testing.T) {
	intl := &statusAdapter{serverName: "FZ-INT-Node", status: outbound.CorplinkStatus{
		Initialized: true, Ready: true, TunnelIP: "10.0.0.2/32", Endpoint: "192.0.2.10:443",
	}}
	fuzhou := &statusAdapter{serverName: "FUZHOU-NODE-1", status: outbound.CorplinkStatus{
		Initialized: true, Ready: false, TunnelIP: "10.0.1.3/32", Endpoint: "192.0.2.11:443",
	}}
	proxies := map[string]C.Proxy{
		"FZ-INT-Node-WG":   statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(intl)},
		"FUZHOU-NODE-1-WG": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(fuzhou)},
		"Airport-A":        statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(&statusAdapter{})},
	}
	statuses := corplinkNodeStatusesFromProxies(proxies)
	if len(statuses) != 2 || statuses[0].ServerName != "FUZHOU-NODE-1" ||
		statuses[1].ServerName != "FZ-INT-Node" {
		t.Fatalf("wrong named status list: %+v", statuses)
	}
	if statuses[0].TunnelIP != "10.0.1.3/32" || statuses[0].Ready ||
		statuses[1].TunnelIP != "10.0.0.2/32" || !statuses[1].Ready {
		t.Fatalf("node status crossed another tunnel: %+v", statuses)
	}
	legacy := corplinkStatusFromProxies(proxies)
	if !legacy.Present || legacy.TunnelIP != "10.0.0.2/32" {
		t.Fatalf("legacy SG status no longer follows INTL: %+v", legacy)
	}
	data, err := json.Marshal(statuses)
	if err != nil || strings.Contains(string(data), "private") || strings.Contains(string(data), "cookie") {
		t.Fatalf("unsafe status JSON: %s, %v", data, err)
	}
}

func TestCorplinkNamedReconnectTouchesOnlyOneNode(t *testing.T) {
	intl := &statusAdapter{serverName: "FZ-INT-Node"}
	fuzhou := &statusAdapter{serverName: "FUZHOU-NODE-1"}
	proxies := map[string]C.Proxy{
		"FZ-INT-Node-WG":   statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(intl)},
		"FUZHOU-NODE-1-WG": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(fuzhou)},
	}
	if !reconnectCorplinkNodeFromProxies(proxies, "FUZHOU-NODE-1") {
		t.Fatal("selected node did not reconnect")
	}
	if fuzhou.reconnects != 1 || intl.reconnects != 0 {
		t.Fatalf("reconnect crossed node boundary: intl=%d fuzhou=%d", intl.reconnects, fuzhou.reconnects)
	}
	if reconnectCorplinkNodeFromProxies(proxies, "unknown") ||
		reconnectCorplinkNodeFromProxies(proxies, "FUZHOU-NODE-1-WG") {
		t.Fatal("unknown or proxy-name input unexpectedly reconnected")
	}
}

func TestCorplinkNamedRebuildTouchesOnlyOneNode(t *testing.T) {
	intl := &statusAdapter{serverName: "FZ-INT-Node"}
	fuzhou := &statusAdapter{serverName: "FUZHOU-NODE-1"}
	proxies := map[string]C.Proxy{
		"FZ-INT-Node-WG":   statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(intl)},
		"FUZHOU-NODE-1-WG": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(fuzhou)},
	}
	if !rebuildCorplinkNodeFromProxies(context.Background(), proxies, "FZ-INT-Node") {
		t.Fatal("selected node was not rebuilt")
	}
	if intl.rebuilds != 1 || fuzhou.rebuilds != 0 {
		t.Fatalf("rebuild crossed node boundary: intl=%d fuzhou=%d", intl.rebuilds, fuzhou.rebuilds)
	}
	if rebuildCorplinkNodeFromProxies(context.Background(), proxies, "missing") {
		t.Fatal("unknown node unexpectedly rebuilt")
	}
}

func TestCorplinkVPNNodeListRejectsMalformedInput(t *testing.T) {
	_, err := handleListCorplinkVPNNodes("{")
	if err == nil {
		t.Fatal("malformed discovery request was accepted")
	}
	if strings.Contains(err.Error(), "Cookie") || strings.Contains(err.Error(), "private") {
		t.Fatal("discovery error exposed authentication material")
	}
}

func TestCorplinkVPNNodeListActionRedactsCookiePath(t *testing.T) {
	got := safeCorplinkNodeListError(errors.New("open /private/cookies.json: secret=do-not-report"))
	if got != "CORPLINK_NODE_LIST_FAILED" {
		t.Fatalf("unsafe node-list error: %q", got)
	}
}

func TestCorplinkVPNNodeListErrorKeepsNumericCodesOnly(t *testing.T) {
	tests := []struct{ raw, want string }{
		{"corplink vpn list HTTP 401 cookie=do-not-report", "corplink vpn list HTTP 401"},
		{"corplink vpn list code 10220001 token=do-not-report", "corplink vpn list code 10220001"},
	}
	for _, tt := range tests {
		got := safeCorplinkNodeListError(errors.New(tt.raw))
		if got != tt.want {
			t.Fatalf("safe error = %q, want %q", got, tt.want)
		}
	}
}

func TestCorplinkVPNNodeListActionReturnsOnlyPublicNames(t *testing.T) {
	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/vpn/list" {
			t.Errorf("unexpected request path: %s", r.URL.Path)
		}
		_, _ = io.WriteString(w, `{"code":0,"data":[`+
			`{"name":"FUZHOU-NODE-1","protocol_mode":1,"ip":"192.0.2.11"},`+
			`{"name":"UDP-NODE","protocol_mode":2,"ip":"192.0.2.12"}]}`)
	}))
	defer control.Close()
	cookiePath := filepath.Join(t.TempDir(), "cookie.json")
	if err := os.WriteFile(cookiePath, []byte("session=test-session"), 0o600); err != nil {
		t.Fatal(err)
	}
	request, err := json.Marshal(corplinkNodeListParams{
		APIServer: control.URL, CookieFile: cookiePath,
		DeviceID: "device-id", DeviceName: "device-name",
	})
	if err != nil {
		t.Fatal(err)
	}
	nodes, err := handleListCorplinkVPNNodes(string(request))
	if err != nil || len(nodes) != 1 || nodes[0].Name != "FUZHOU-NODE-1" {
		t.Fatalf("wrong action result: nodes=%+v err=%v", nodes, err)
	}
	data, err := json.Marshal(nodes)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "192.0.2.") || strings.Contains(string(data), "test-session") {
		t.Fatal("core action returned internal endpoint or Cookie")
	}
}

func TestReconnectCorplinkOnlyLeavesOtherWireGuardAlone(t *testing.T) {
	sg := &statusAdapter{}
	other := &statusAdapter{}
	proxies := map[string]C.Proxy{
		"SG-Node": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(sg)},
		"airport": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(other)},
	}
	if !reconnectCorplinkFromProxies(proxies) {
		t.Fatal("SG outbound not reconnected")
	}
	if sg.reconnects != 1 || other.reconnects != 0 {
		t.Fatalf("reconnect counts: SG=%d airport=%d", sg.reconnects, other.reconnects)
	}
	if reconnectCorplinkFromProxies(map[string]C.Proxy{"airport": proxies["airport"]}) {
		t.Fatal("missing SG outbound reported reconnect success")
	}
}

func TestCollectReconnectableIncludesWrappedWireGuardAdapters(t *testing.T) {
	sg := &statusAdapter{}
	other := &statusAdapter{}
	proxies := map[string]C.Proxy{
		"SG-Node": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(sg)},
		"airport": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(other)},
	}
	adapters := collectReconnectable(proxies)
	if len(adapters) != 2 {
		t.Fatalf("collected %d reconnectable adapters, want 2", len(adapters))
	}
	for _, adapter := range adapters {
		adapter.Reconnect()
	}
	if sg.reconnects != 1 || other.reconnects != 1 {
		t.Fatalf("network-change reconnect counts: SG=%d airport=%d", sg.reconnects, other.reconnects)
	}
}
