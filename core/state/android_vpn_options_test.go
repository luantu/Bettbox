package state

import (
	"encoding/json"
	"net/netip"
	"strings"
	"testing"
)

func TestAndroidVpnOptionsSerializesRouteExclusions(t *testing.T) {
	data, err := json.Marshal(AndroidVpnOptions{
		RouteExcludeAddress: []netip.Prefix{
			netip.MustParsePrefix("192.168.110.0/24"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"routeExcludeAddress":["192.168.110.0/24"]`) {
		t.Fatalf("route exclusions missing from Android options: %s", data)
	}
}
