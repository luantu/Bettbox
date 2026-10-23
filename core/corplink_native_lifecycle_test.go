package main

import (
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"testing"
)

type nativeLifecycleAdapter struct {
	statusAdapter
	states []bool
}

func (a *nativeLifecycleAdapter) SetCorplinkNativeActive(active bool) error {
	a.states = append(a.states, active)
	return nil
}

func TestNativeLifecycleReachesEveryWrappedCorplinkNodeOnce(t *testing.T) {
	a, b := &nativeLifecycleAdapter{}, &nativeLifecycleAdapter{}
	pa := statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(a)}
	proxies := map[string]C.Proxy{
		"a-WG": pa, "a-alias": pa,
		"b-WG":    statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(b)},
		"airport": statusProxy{adapter: outbound.NewAutoCloseProxyAdapter(&statusAdapter{})},
	}
	setCorplinkNativeActiveFromProxies(proxies, false)
	setCorplinkNativeActiveFromProxies(proxies, true)
	for _, n := range []*nativeLifecycleAdapter{a, b} {
		if len(n.states) != 2 || n.states[0] || !n.states[1] {
			t.Fatalf("lost/duplicate lifecycle event: %v", n.states)
		}
	}
}
