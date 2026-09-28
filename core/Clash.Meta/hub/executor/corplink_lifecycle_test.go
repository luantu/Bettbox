package executor

import (
	"testing"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
)

type lifecycleProxy struct {
	C.Proxy
	adapter C.ProxyAdapter
}

func (p *lifecycleProxy) Adapter() C.ProxyAdapter { return p.adapter }

type lifecycleAdapter struct {
	outbound.ProxyAdapter
	corplink bool
	closed   int
}

func (a *lifecycleAdapter) IsCorplink() bool { return a.corplink }
func (a *lifecycleAdapter) Name() string     { return "test" }
func (a *lifecycleAdapter) Close() error {
	a.closed++
	return nil
}

func TestCloseReplacedCorplinkProxiesClosesOldInstanceOnly(t *testing.T) {
	oldSG := &lifecycleAdapter{corplink: true}
	newSG := &lifecycleAdapter{corplink: true}
	oldAirport := &lifecycleAdapter{}
	old := map[string]C.Proxy{
		"SG-Node": &lifecycleProxy{adapter: outbound.NewAutoCloseProxyAdapter(oldSG)},
		"airport": &lifecycleProxy{adapter: outbound.NewAutoCloseProxyAdapter(oldAirport)},
	}
	newProxies := map[string]C.Proxy{
		"SG-Node": &lifecycleProxy{adapter: outbound.NewAutoCloseProxyAdapter(newSG)},
		"airport": old["airport"],
	}

	closeReplacedCorplinkProxies(old, newProxies)
	if oldSG.closed != 1 || newSG.closed != 0 || oldAirport.closed != 0 {
		t.Fatalf("close counts: old SG=%d new SG=%d airport=%d", oldSG.closed, newSG.closed, oldAirport.closed)
	}
}

func TestCloseReplacedCorplinkProxiesPreservesReusedInstance(t *testing.T) {
	sg := &lifecycleAdapter{corplink: true}
	proxy := &lifecycleProxy{adapter: outbound.NewAutoCloseProxyAdapter(sg)}
	closeReplacedCorplinkProxies(
		map[string]C.Proxy{"SG-Node": proxy},
		map[string]C.Proxy{"SG-Node": proxy},
	)
	if sg.closed != 0 {
		t.Fatalf("reused adapter closed %d times", sg.closed)
	}
}
