package config

import (
	"strings"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/fakeip"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	RC "github.com/metacubex/mihomo/rules/common"
)

type privateDNSTestAdapter struct {
	C.ProxyAdapter
	info     outbound.CorplinkDNSPolicyInfo
	matchers []C.DomainMatcher
}

func (d *privateDNSTestAdapter) CorplinkDNSPolicyInfo() outbound.CorplinkDNSPolicyInfo {
	return d.info
}

func (*privateDNSTestAdapter) CorplinkDNSAddress() (string, error) {
	return "10.0.0.53:53", nil
}

func (d *privateDNSTestAdapter) SetCorplinkDNSMatchers(matchers []C.DomainMatcher) {
	d.matchers = append([]C.DomainMatcher(nil), matchers...)
}

func (d *privateDNSTestAdapter) MatchCorplinkPrivateDomain(domain string) bool {
	if domain == d.info.HealthHost {
		return true
	}
	for _, suffix := range d.info.Domains {
		if domain == suffix || strings.HasSuffix(domain, "."+suffix) {
			return true
		}
	}
	for _, matcher := range d.matchers {
		if matcher.MatchDomain(domain) {
			return true
		}
	}
	return false
}

func TestCorplinkDNSPolicyPrecedesExistingSystemPolicy(t *testing.T) {
	private := &privateDNSTestAdapter{info: outbound.CorplinkDNSPolicyInfo{
		ServerName: "Fuzhou-Node-1",
		Domains:    []string{"corp.example.invalid"},
		HealthHost: "api.inside.example.invalid",
	}}
	proxies := map[string]C.Proxy{
		"Fuzhou-Node-1-WG": adapter.NewProxy(private),
	}
	rules := []C.Rule{
		RC.NewDomainSuffix("inside.example.invalid", "Fuzhou-Node-1"),
	}
	dnsConfig := &DNS{FakeIPSkipper: &fakeip.Skipper{Mode: C.FilterBlackList}, NameServerPolicy: []dns.Policy{{
		Domain: "*", NameServers: []dns.NameServer{{Net: "system"}},
	}}}
	if err := appendCorplinkDNSPolicies(dnsConfig, proxies, rules, nil); err != nil {
		t.Fatalf("append private DNS policies: %v", err)
	}
	if got := len(dnsConfig.NameServerPolicy); got != 2 {
		t.Fatalf("policy count = %d, want dynamic private scope and original", got)
	}
	protected := dnsConfig.NameServerPolicy[0]
	if len(private.matchers) != 1 || protected.Matcher == nil ||
		len(protected.NameServers) != 2 ||
		protected.NameServers[0].Net != "" ||
		protected.NameServers[1].Net != "tcp" ||
		protected.NameServers[0].ProxyAdapter != private ||
		protected.NameServers[1].ProxyAdapter != private ||
		!protected.NameServers[0].DynamicAddress ||
		!protected.NameServers[1].DynamicAddress {
		t.Fatal("protected DNS policy is not dynamically bound to Fuzhou")
	}
	for _, domain := range []string{
		"host.inside.example.invalid", "host.corp.example.invalid", "api.inside.example.invalid",
	} {
		if !protected.Matcher.MatchDomain(domain) {
			t.Fatalf("missing protected DNS policy")
		}
	}
	if !dnsConfig.FakeIPSkipper.ShouldSkipped("api.inside.example.invalid") ||
		dnsConfig.FakeIPSkipper.ShouldSkipped("chatgpt.com") {
		t.Fatal("fake-IP filter did not use the private DNS scope")
	}
	private.info.Domains = []string{"new.example.invalid"}
	if protected.Matcher.MatchDomain("host.corp.example.invalid") ||
		!protected.Matcher.MatchDomain("host.new.example.invalid") {
		t.Fatal("rebuilt session domain scope stayed stale")
	}
	if !dnsConfig.FakeIPSkipper.ShouldSkipped("host.new.example.invalid") {
		t.Fatal("fake-IP filter kept the old session scope")
	}
	if dnsConfig.NameServerPolicy[1].Domain != "*" ||
		dnsConfig.NameServerPolicy[1].NameServers[0].Net != "system" {
		t.Fatal("existing DNS policy was overwritten")
	}
}
