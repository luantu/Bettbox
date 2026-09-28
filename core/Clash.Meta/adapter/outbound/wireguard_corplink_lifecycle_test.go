package outbound

import (
	"net/netip"
	"testing"
)

type statusBind struct {
	wireGuardBind
	ready bool
}

func (b *statusBind) IsConnReady(string) bool { return b.ready }

type lifecycleDevice struct {
	wireguardGoDevice
	ipcSets int
}

func (d *lifecycleDevice) IpcSet(string) error {
	d.ipcSets++
	return nil
}

func TestCorplinkFailureRequiresFreshIPStackInsteadOfLiveAddressRewrite(t *testing.T) {
	device := &lifecycleDevice{}
	address := netip.MustParsePrefix("10.11.12.13/32")
	w := &WireGuard{
		device: device,
		option: WireGuardOption{
			Ip:       "10.11.12.13/32",
			Corplink: CorplinkOption{APIServer: "https://invalid.example"},
		},
		localPrefixes: []netip.Prefix{address},
	}

	w.refreshCorplinkAfterTunnelFailure()
	if !w.requiresRebuild.Load() {
		t.Fatal("CorpLink failure did not request a fresh IP stack")
	}
	if w.option.Ip != address.String() || w.localPrefixes[0] != address {
		t.Fatal("live WireGuard address changed without replacing the IP stack")
	}
	if device.ipcSets != 0 {
		t.Fatal("live WireGuard peer was changed without replacing the IP stack")
	}
}

func TestCorplinkStatusSeparatesInitializationFromHandshake(t *testing.T) {
	bind := &statusBind{}
	w := &WireGuard{
		bind: bind,
		option: WireGuardOption{
			TCP:      true,
			Ip:       "10.11.12.13/32",
			Corplink: CorplinkOption{APIServer: "https://management.example"},
		},
	}
	w.initOk.Store(true)
	status := w.CorplinkStatus()
	if !status.Initialized || status.Ready || status.TunnelIP != "10.11.12.13/32" {
		t.Fatalf("wrong pre-handshake status: %+v", status)
	}
	bind.ready = true
	status = w.CorplinkStatus()
	if !status.Ready {
		t.Fatalf("handshake completion not visible: %+v", status)
	}
	w.requiresRebuild.Store(true)
	status = w.CorplinkStatus()
	if !status.RebuildRequired || status.Ready {
		t.Fatalf("rebuild requirement hidden by old ready socket: %+v", status)
	}
}

func TestTCPBindReadyStatusDoesNotDependOnEndpointSpelling(t *testing.T) {
	bind := &tcpWireGuardBind{}
	state := newTCPConnState(nil, 1)
	state.markReady()
	bind.tcpConnMap.Store("192.0.2.1:34080", state)
	if !bind.HasReadyConn() {
		t.Fatal("completed handshake was not visible after endpoint resolution")
	}
	bind.closed.Store(true)
	if bind.HasReadyConn() {
		t.Fatal("closed transport reported a ready connection")
	}
}
