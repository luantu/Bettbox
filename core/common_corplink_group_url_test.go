package main

import (
	"testing"

	"github.com/metacubex/mihomo/config"
)

func TestGlobalDelayOverrideKeepsManagedCorplinkProbe(t *testing.T) {
	raw, err := config.UnmarshalRawConfig([]byte(`
proxies:
  - name: Corp-Node-WG
    type: wireguard
    corplink:
      corplink-vpn-server-name: Corp-Node
  - name: Airport-A
    type: socks5
proxy-groups:
  - name: Corp-Node
    type: select
    proxies: [Corp-Node-WG]
    url: https://private.example.invalid/ready
  - name: Airport
    type: select
    proxies: [Airport-A]
    url: https://airport.example.invalid/ready
`))
	if err != nil {
		t.Fatal(err)
	}

	overrideGroupTestURLs(raw, "https://global.example.invalid/generate_204")
	if got := raw.ProxyGroup[0]["url"]; got != "https://private.example.invalid/ready" {
		t.Fatalf("managed CorpLink probe was overwritten: %v", got)
	}
	if got := raw.ProxyGroup[1]["url"]; got != "https://global.example.invalid/generate_204" {
		t.Fatalf("airport group did not obey global test URL: %v", got)
	}
}

func TestGlobalDelayOverrideDoesNotTrustSimilarUnmanagedGroup(t *testing.T) {
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		{"name": "Airport-WG", "type": "wireguard"},
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "Airport", "type": "select", "proxies": []string{"Airport-WG"}, "url": "https://airport.example.invalid/ready"},
	}

	overrideGroupTestURLs(raw, "https://global.example.invalid/generate_204")
	if got := raw.ProxyGroup[0]["url"]; got != "https://global.example.invalid/generate_204" {
		t.Fatalf("unmanaged WireGuard group bypassed global URL: %v", got)
	}
}
