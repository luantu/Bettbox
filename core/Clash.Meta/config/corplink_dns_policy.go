package config

import (
	"errors"
	"sort"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/dns"
)

type corplinkDomainRuleMatcher struct{ rule C.Rule }

func (m corplinkDomainRuleMatcher) MatchDomain(domain string) bool {
	matched, _ := m.rule.Match(&C.Metadata{Host: domain}, C.RuleMatchHelper{})
	return matched
}

type corplinkProviderDomainMatcher struct{ provider P.RuleProvider }

func (m corplinkProviderDomainMatcher) MatchDomain(domain string) bool {
	// An empty or not-yet-loaded provider cannot match a routing rule either.
	// Never widen its DNS policy to unrelated public domains.
	return m.provider.Match(&C.Metadata{Host: domain}, C.RuleMatchHelper{})
}

type corplinkAnyDomainMatcher struct{ matchers []C.DomainMatcher }

func (m corplinkAnyDomainMatcher) MatchDomain(domain string) bool {
	for _, matcher := range m.matchers {
		if matcher.MatchDomain(domain) {
			return true
		}
	}
	return false
}

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
			MatchCorplinkPrivateDomain(string) bool
			SetCorplinkDNSMatchers([]C.DomainMatcher)
		})
		if !ok {
			continue
		}
		info := wg.CorplinkDNSPolicyInfo()
		if info.ServerName == "" || name != info.ServerName+"-WG" {
			continue
		}
		upstreams := outbound.CorplinkPrivateNameServers(proxy.Adapter())
		matchers := make([]C.DomainMatcher, 0)
		for _, rule := range rules {
			if rule.Adapter() != info.ServerName {
				continue
			}
			if wrapped, ok := rule.(C.RuleWrapper); ok {
				if wrapped.IsDisabled() {
					continue
				}
				rule = wrapped.Unwrap()
			}
			switch rule.RuleType() {
			case C.Domain, C.DomainSuffix, C.DomainKeyword,
				C.DomainRegex, C.DomainWildcard, C.GEOSITE:
				matchers = append(matchers, corplinkDomainRuleMatcher{rule: rule})
			case C.RuleSet:
				provider, found := ruleProviders[rule.Payload()]
				if !found {
					return errors.New("corplink DNS rule provider unavailable")
				}
				if provider.Behavior() == P.IPCIDR {
					continue // IP-only sets have no query name to protect.
				}
				matchers = append(matchers, corplinkProviderDomainMatcher{provider: provider})
			default:
				continue // Non-domain rules cannot choose DNS before routing.
			}
		}
		wg.SetCorplinkDNSMatchers(matchers)
		generated = append(generated, dns.Policy{
			Matcher:     outbound.NewCorplinkPrivateDNSMatcher(proxy.Adapter()),
			NameServers: upstreams,
		})
	}
	if len(generated) != 0 {
		config.NameServerPolicy = append(generated, config.NameServerPolicy...)
		if config.FakeIPSkipper != nil {
			matchers := make([]C.DomainMatcher, 0, len(generated)+1)
			if config.FakeIPSkipper.ForceRealIP != nil {
				matchers = append(matchers, config.FakeIPSkipper.ForceRealIP)
			}
			for _, policy := range generated {
				matchers = append(matchers, policy.Matcher)
			}
			config.FakeIPSkipper.ForceRealIP = corplinkAnyDomainMatcher{matchers: matchers}
		}
	}
	return nil
}
