package main

import (
	"encoding/json"
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
	reconnects int
}

func (a *statusAdapter) CorplinkStatus() outbound.CorplinkStatus { return a.status }
func (a *statusAdapter) Reconnect()                              { a.reconnects++ }
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
