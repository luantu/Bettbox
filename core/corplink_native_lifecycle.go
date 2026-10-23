package main

import (
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

func setCorplinkNativeActiveFromProxies(proxies map[string]C.Proxy, active bool) {
	seen := map[C.ProxyAdapter]bool{}
	for _, proxy := range proxies {
		adapter := outbound.UnderlyingProxyAdapter(proxy.Adapter())
		if adapter == nil || seen[adapter] {
			continue
		}
		seen[adapter] = true
		if node, ok := adapter.(interface{ SetCorplinkNativeActive(bool) error }); ok {
			if err := node.SetCorplinkNativeActive(active); err != nil {
				log.Warnln("[SG lifecycle] native transition failed active=%t", active)
			}
		}
	}
}

func setCorplinkNativeActive(active bool) {
	runLock.Lock()
	defer runLock.Unlock()
	if isInit {
		setCorplinkNativeActiveFromProxies(tunnel.Proxies(), active)
	}
}
