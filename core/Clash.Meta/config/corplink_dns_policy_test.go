package config

import (
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	RC "github.com/metacubex/mihomo/rules/common"
)

type privateDNSTestAdapter struct {
	C.ProxyAdapter
}

func (*privateDNSTestAdapter) CorplinkDNSPolicyInfo() outbound.CorplinkDNSPolicyInfo {
	return outbound.CorplinkDNSPolicyInfo{
		ServerName: "Fuzhou-Node-1",
		Domains:    []string{"corp.example.invalid"},
		HealthHost: "api.inside.example.invalid",
	}
}

func (*privateDNSTestAdapter) CorplinkDNSAddress() (string, error) {
	return "10.0.0.53:53", nil
}

func TestCorplinkDNSPolicyPrecedesExistingSystemPolicy(t *testing.T) {
	private := &privateDNSTestAdapter{}
	proxies := map[string]C.Proxy{
		"Fuzhou-Node-1-WG": adapter.NewProxy(private),
	}
	rules := []C.Rule{
		RC.NewDomainSuffix("inside.example.invalid", "Fuzhou-Node-1"),
	}
	dnsConfig := &DNS{NameServerPolicy: []dns.Policy{{
		Domain: "*", NameServers: []dns.NameServer{{Net: "system"}},
	}}}
	if err := appendCorplinkDNSPolicies(dnsConfig, proxies, rules, nil); err != nil {
		t.Fatalf("append private DNS policies: %v", err)
	}
	if got := len(dnsConfig.NameServerPolicy); got != 4 {
		t.Fatalf("policy count = %d, want protected domain, split, health and original", got)
	}
	protected := map[string]bool{}
	for _, policy := range dnsConfig.NameServerPolicy[:3] {
		protected[policy.Domain] = true
		if len(policy.NameServers) != 1 ||
			policy.NameServers[0].ProxyAdapter != private ||
			!policy.NameServers[0].DynamicAddress {
			t.Fatal("protected DNS policy is not bound to the Fuzhou outbound")
		}
	}
	for _, domain := range []string{
		"+.inside.example.invalid", "+.corp.example.invalid", "api.inside.example.invalid",
	} {
		if !protected[domain] {
			t.Fatalf("missing protected DNS policy")
		}
	}
	if dnsConfig.NameServerPolicy[3].Domain != "*" ||
		dnsConfig.NameServerPolicy[3].NameServers[0].Net != "system" {
		t.Fatal("existing DNS policy was overwritten")
	}
}
