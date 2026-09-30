package outbound

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestCorplinkRoutesReadActualSplitAndFullFields(t *testing.T) {
	var response corplinkRespWgInfo
	if err := json.Unmarshal([]byte(`{"code":0,"data":{"setting":{"vpn_route_split":["10.20.3.4/16","192.0.2.7","10.20.0.0/16","bad-route"],"v6_route_split":["2001:db8:1::7/64"],"vpn_route_full":["0.0.0.0/0"],"v6_route_full":["::/0"]}}}`), &response); err != nil {
		t.Fatal(err)
	}
	routes := corplinkRoutesFromSettings(response.Data.Setting)
	if !routes.Present || routes.Invalid != 1 {
		t.Fatal("actual route metadata presence or invalid count was lost")
	}
	if !reflect.DeepEqual(routes.Split, []string{"10.20.0.0/16", "192.0.2.7/32", "2001:db8:1::/64"}) {
		t.Fatal("server split routes were not normalized or deduplicated")
	}
	if !reflect.DeepEqual(routes.Full, []string{"0.0.0.0/0", "::/0"}) {
		t.Fatal("full-tunnel routes must remain separate from split routes")
	}
}

func TestCorplinkRoutesDistinguishMissingFromEmpty(t *testing.T) {
	for _, fixture := range []struct {
		raw     string
		present bool
	}{
		{`{"data":{"setting":{"vpn_mtu":1400}}}`, false},
		{`{"data":{"setting":{"vpn_route_split":[]}}}`, true},
		{`{"data":{}}`, false},
	} {
		var response corplinkRespWgInfo
		if err := json.Unmarshal([]byte(fixture.raw), &response); err != nil {
			t.Fatal(err)
		}
		if got := corplinkRoutesFromSettings(response.Data.Setting); got.Present != fixture.present || len(got.Split) != 0 {
			t.Fatal("missing and explicitly empty server route lists were conflated")
		}
	}
}

func TestCorplinkRouteStatusIsCopiedAndInvalidatedWithSession(t *testing.T) {
	w := &WireGuard{option: WireGuardOption{corplinkRoutes: corplinkRouteInfo{
		Present: true, Split: []string{"10.20.0.0/16"}, Full: []string{"0.0.0.0/0"}, Invalid: 1,
	}}}
	status := w.CorplinkStatus()
	if !status.RoutesPresent || status.RouteInvalid != 1 || len(status.RouteSplit) != 1 {
		t.Fatal("session routes missing from telemetry")
	}
	status.RouteSplit[0] = "192.0.2.0/24"
	status.RouteFull[0] = "::/0"
	if w.option.corplinkRoutes.Split[0] != "10.20.0.0/16" || w.option.corplinkRoutes.Full[0] != "0.0.0.0/0" {
		t.Fatal("telemetry aliases mutable session route storage")
	}
	w.requiresRebuild.Store(true)
	stale := w.CorplinkStatus()
	if stale.RoutesPresent || len(stale.RouteSplit) != 0 || len(stale.RouteFull) != 0 || stale.RouteInvalid != 0 {
		t.Fatal("uninitialized rebuild exposes stale routes as current session")
	}
}
