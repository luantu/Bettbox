package config

import (
	"errors"
	"net/netip"
	"sort"
	"strings"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/dns"
)

// appendCorplinkDNSPolicies runs after proxies and rules have been parsed but
// before the global DNS resolver is built. A domain routed to a private VPN
// node must not first be resolved by the phone's existing DNS policy.
func appendCorplinkDNSPolicies(
	config *DNS,
	proxies map[string]C.Proxy,
	rules []C.Rule,
	ruleProviders map[string]P.RuleProvider,
) error {
	if config == nil {
		return nil
	}
	proxyNames := make([]string, 0, len(proxies))
	for name := range proxies {
		proxyNames = append(proxyNames, name)
	}
	sort.Strings(proxyNames)
	generated := make([]dns.Policy, 0)
	for _, name := range proxyNames {
		proxy := proxies[name]
		wg, ok := proxy.Adapter().(interface {
			CorplinkDNSPolicyInfo() outbound.CorplinkDNSPolicyInfo
			CorplinkDNSAddress() (string, error)
		})
		if !ok {
			continue
		}
		info := wg.CorplinkDNSPolicyInfo()
		if info.ServerName == "" || name != info.ServerName+"-WG" {
			continue
		}
		upstream := dns.NameServer{
			Net: "", Addr: "192.0.2.1:53", ProxyAdapter: proxy.Adapter(),
			DynamicAddress: true,
		}
		seen := map[string]bool{}
		addDomain := func(domain string) {
			if domain == "" || seen[domain] {
				return
			}
			seen[domain] = true
			generated = append(generated, dns.Policy{
				Domain: domain, NameServers: []dns.NameServer{upstream},
			})
		}
		for _, rule := range rules {
			if rule.Adapter() != info.ServerName {
				continue
			}
			switch rule.RuleType() {
			case C.Domain:
				addDomain(strings.ToLower(rule.Payload()))
			case C.DomainSuffix:
				addDomain("+." + strings.TrimPrefix(strings.ToLower(rule.Payload()), "."))
			case C.RuleSet:
				provider, found := ruleProviders[rule.Payload()]
				if !found {
					return errors.New("corplink DNS rule provider unavailable")
				}
				if provider.Behavior() == P.IPCIDR {
					continue // An IP-only rule has no pre-route domain to resolve.
				}
				matcher, err := parseDomainRuleSet(rule.Payload(), "corplink DNS", ruleProviders)
				if err != nil {
					return errors.New("corplink DNS rule provider invalid")
				}
				generated = append(generated, dns.Policy{
					Matcher: matcher, NameServers: []dns.NameServer{upstream},
				})
			}
		}
		for _, domain := range info.Domains {
			addDomain("+." + domain)
		}
		if info.HealthHost != "" {
			if _, err := netip.ParseAddr(info.HealthHost); err != nil {
				addDomain(strings.ToLower(info.HealthHost))
			}
		}
	}
	if len(generated) != 0 {
		config.NameServerPolicy = append(generated, config.NameServerPolicy...)
	}
	return nil
}
