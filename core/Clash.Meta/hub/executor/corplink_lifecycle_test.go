package executor

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

type lifecycleProxy struct {
	C.Proxy
	adapter C.ProxyAdapter
}

func (p *lifecycleProxy) Adapter() C.ProxyAdapter { return p.adapter }

type lifecycleAdapter struct {
	C.ProxyAdapter
	corplink bool
	closed   int
}

func (a *lifecycleAdapter) IsCorplink() bool { return a.corplink }
func (a *lifecycleAdapter) Close() error {
	a.closed++
	return nil
}

func TestCloseReplacedCorplinkProxiesClosesOldInstanceOnly(t *testing.T) {
	oldSG := &lifecycleAdapter{corplink: true}
	newSG := &lifecycleAdapter{corplink: true}
	oldAirport := &lifecycleAdapter{}
	old := map[string]C.Proxy{
		"SG-Node": &lifecycleProxy{adapter: oldSG},
		"airport": &lifecycleProxy{adapter: oldAirport},
	}
	newProxies := map[string]C.Proxy{
		"SG-Node": &lifecycleProxy{adapter: newSG},
		"airport": old["airport"],
	}

	closeReplacedCorplinkProxies(old, newProxies)
	if oldSG.closed != 1 || newSG.closed != 0 || oldAirport.closed != 0 {
		t.Fatalf("close counts: old SG=%d new SG=%d airport=%d", oldSG.closed, newSG.closed, oldAirport.closed)
	}
}

func TestCloseReplacedCorplinkProxiesPreservesReusedInstance(t *testing.T) {
	sg := &lifecycleAdapter{corplink: true}
	proxy := &lifecycleProxy{adapter: sg}
	closeReplacedCorplinkProxies(
		map[string]C.Proxy{"SG-Node": proxy},
		map[string]C.Proxy{"SG-Node": proxy},
	)
	if sg.closed != 0 {
		t.Fatalf("reused adapter closed %d times", sg.closed)
	}
}
