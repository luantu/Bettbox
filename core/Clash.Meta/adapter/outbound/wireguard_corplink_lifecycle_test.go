package outbound

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
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

type trackingLifecycleDevice struct {
	wireguardGoDevice
	closes atomic.Int32
}

func (d *trackingLifecycleDevice) Close() {
	d.closes.Add(1)
	d.wireguardGoDevice.Close()
}

func TestCorplinkRebuildChangesOnlyNamedIPStack(t *testing.T) {
	const serverPublic = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	var firstNodeCalls atomic.Int32
	makeData := func(nextIP func() string) (*httptest.Server, string) {
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/vpn/ping" {
				_, _ = io.WriteString(w, `{"code":0,"data":"ok"}`)
				return
			}
			if r.URL.Path != "/vpn/conn" {
				http.NotFound(w, r)
				return
			}
			_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":{"ip":%q,"ip_mask":"32","public_key":%q,"setting":{"vpn_mtu":1400}}}`, nextIP(), serverPublic))
		}))
		_, port, err := net.SplitHostPort(server.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		return server, port
	}
	dataA, portA := makeData(func() string {
		if firstNodeCalls.Add(1) == 1 {
			return "10.21.0.2"
		}
		return "10.21.0.3"
	})
	defer dataA.Close()
	dataB, portB := makeData(func() string { return "10.22.0.2" })
	defer dataB.Close()
	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":[`+
			`{"api_port":%s,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FZ-INT-Node"},`+
			`{"api_port":%s,"vpn_port":34081,"ip":"127.0.0.1","protocol_mode":1,"name":"FUZHOU-NODE-1"}]}`, portA, portB))
	}))
	defer control.Close()
	cookiePath := writeCorplinkCookieFile(t)
	makeOption := func(name string) WireGuardOption {
		return WireGuardOption{
			Name: name + "-WG", TCP: true, Ip: "0.0.0.0/32",
			PrivateKey: base64.StdEncoding.EncodeToString([]byte(strings.Repeat("c", 32))),
			WireGuardPeerOption: WireGuardPeerOption{
				Server: "127.0.0.1", Port: 34080, PublicKey: serverPublic,
				AllowedIPs: []string{"0.0.0.0/0"},
			},
			Corplink: CorplinkOption{
				APIServer: control.URL, CookieFile: cookiePath,
				VPNServerName: name,
				PublicKey:     base64.StdEncoding.EncodeToString([]byte(strings.Repeat("d", 32))),
				Code:          "JBSWY3DPEHPK3PXP",
			},
		}
	}
	a, err := NewWireGuard(makeOption("FZ-INT-Node"))
	if err != nil {
		t.Fatalf("build node A: %v", err)
	}
	defer a.Close()
	b, err := NewWireGuard(makeOption("FUZHOU-NODE-1"))
	if err != nil {
		t.Fatalf("build node B: %v", err)
	}
	defer b.Close()
	oldA := &trackingLifecycleDevice{wireguardGoDevice: a.device}
	a.device = oldA
	oldB := b.device
	a.requiresRebuild.Store(true)
	if err := a.RebuildCorplink(context.Background()); err != nil {
		t.Fatalf("rebuild node A: %v", err)
	}
	if a.option.Ip != "10.21.0.3/32" || a.localPrefixes[0] != netip.MustParsePrefix("10.21.0.3/32") {
		t.Fatalf("node A retained old IP stack: %s %+v", a.option.Ip, a.localPrefixes)
	}
	if oldA.closes.Load() != 1 || a.device == oldA || a.requiresRebuild.Load() {
		t.Fatalf("node A old device not replaced: closes=%d rebuild=%t", oldA.closes.Load(), a.requiresRebuild.Load())
	}
	if b.device != oldB || b.option.Ip != "10.22.0.2/32" {
		t.Fatalf("node B changed during A rebuild: ip=%s", b.option.Ip)
	}
	var operations sync.WaitGroup
	start := make(chan struct{})
	operations.Add(2)
	go func() {
		defer operations.Done()
		<-start
		_ = a.RebuildCorplink(context.Background())
	}()
	go func() {
		defer operations.Done()
		<-start
		_ = a.Close()
	}()
	close(start)
	done := make(chan struct{})
	go func() {
		operations.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("concurrent rebuild/close did not finish")
	}
	if !a.closed.Load() || b.device != oldB {
		t.Fatal("close lost or another node changed during rebuild race")
	}
}

func TestCorplinkUnavailableAtLoadCanRebuildAfterServerRecovery(t *testing.T) {
	const serverPublic = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	data := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/vpn/ping" {
			_, _ = io.WriteString(w, `{"code":0,"data":"ok"}`)
			return
		}
		_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":{"ip":"10.31.0.4","ip_mask":"32","public_key":%q}}`, serverPublic))
	}))
	defer data.Close()
	_, port, err := net.SplitHostPort(data.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	var available atomic.Bool
	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !available.Load() {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":[{"api_port":%s,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FZ-INT-Node"}]}`, port))
	}))
	defer control.Close()
	localKey := base64.StdEncoding.EncodeToString(make([]byte, 32))
	w, err := NewWireGuard(WireGuardOption{
		Name: "FZ-INT-Node-WG", TCP: true, Ip: "0.0.0.0/32",
		PrivateKey: localKey,
		WireGuardPeerOption: WireGuardPeerOption{
			Server: "127.0.0.1", Port: 34080, PublicKey: serverPublic,
			AllowedIPs: []string{"0.0.0.0/0"},
		},
		Corplink: CorplinkOption{
			APIServer: control.URL, CookieFile: writeCorplinkCookieFile(t),
			VPNServerName: "FZ-INT-Node", PublicKey: localKey,
			Code: "JBSWY3DPEHPK3PXP",
		},
	})
	if err != nil {
		t.Fatalf("unavailable node rejected at profile load: %v", err)
	}
	defer w.Close()
	if w.device != nil || !w.CorplinkStatus().RebuildRequired || w.CorplinkStatus().TunnelIP != "" {
		t.Fatalf("unavailable node did not stay fail-closed: %+v", w.CorplinkStatus())
	}
	available.Store(true)
	if err := w.RebuildCorplink(context.Background()); err != nil {
		t.Fatalf("server recovery could not rebuild the node: %v", err)
	}
	if w.device == nil || w.option.Ip != "10.31.0.4/32" || w.CorplinkStatus().RebuildRequired {
		t.Fatalf("recovered node did not adopt its own new stack: %+v", w.CorplinkStatus())
	}
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

func TestCorplinkSuccessfulDataPlaneClearsPendingRebuild(t *testing.T) {
	w := &WireGuard{}
	w.requiresRebuild.Store(true)
	w.recordBusySuccess()
	if w.requiresRebuild.Load() {
		t.Fatal("successful tunneled connection left rebuild request latched")
	}
}
