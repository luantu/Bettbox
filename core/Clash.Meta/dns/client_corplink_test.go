package dns

import (
	"errors"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

type dynamicDNSAdapter struct {
	C.ProxyAdapter
	address string
}

func (d *dynamicDNSAdapter) CorplinkDNSAddress() (string, error) {
	return d.address, nil
}

func TestDynamicPrivateDNSAddressChangesWithoutPublicFallback(t *testing.T) {
	current := "10.0.0.53:53"
	c := &client{
		host: "192.0.2.1", port: "53",
		dynamicAddress: func() (string, error) {
			if current == "" {
				return "", errors.New("VPN DNS unavailable")
			}
			return current, nil
		},
	}
	if address, err := c.dialAddress(); err != nil || address != "10.0.0.53:53" {
		t.Fatal("initial VPN DNS address was not used")
	}
	current = "10.0.0.54:53"
	if address, err := c.dialAddress(); err != nil || address != "10.0.0.54:53" {
		t.Fatal("VPN DNS address stayed stale after rebuild")
	}
	current = ""
	if address, err := c.dialAddress(); err == nil || address != "" {
		t.Fatal("missing VPN DNS fell back to the static public address")
	}
}

func TestDynamicPrivateDNSNameServerUsesItsProxyAddressProvider(t *testing.T) {
	adapter := &dynamicDNSAdapter{address: "10.0.0.53:53"}
	servers := transform([]NameServer{{
		Net: "", Addr: "192.0.2.1:53", ProxyAdapter: adapter,
		DynamicAddress: true,
	}}, nil)
	if len(servers) != 1 {
		t.Fatal("dynamic DNS name server was not constructed")
	}
	client, ok := servers[0].(*client)
	if !ok {
		t.Fatal("unexpected dynamic DNS transport")
	}
	if address, err := client.dialAddress(); err != nil || address != "10.0.0.53:53" {
		t.Fatal("name server ignored the node's DNS address")
	}
	adapter.address = "10.0.0.54:53"
	if address, err := client.dialAddress(); err != nil || address != "10.0.0.54:53" {
		t.Fatal("name server retained stale DNS after node rebuild")
	}
}
