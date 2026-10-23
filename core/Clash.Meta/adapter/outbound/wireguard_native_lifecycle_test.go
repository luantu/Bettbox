package outbound

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"testing"
)

type nativeLifecycleDevice struct {
	wireguardGoDevice
	ups, downs, closes int
}

func (d *nativeLifecycleDevice) Up() error   { d.ups++; return nil }
func (d *nativeLifecycleDevice) Down() error { d.downs++; return nil }
func (d *nativeLifecycleDevice) Close()      { d.closes++ }

func TestCorplinkHardStopQuiescesPeersWithoutReplacingDevice(t *testing.T) {
	allowed := false
	installNativeGuardTestHook(t, func() bool { return allowed })
	dev := &nativeLifecycleDevice{}
	w := &WireGuard{device: dev, option: WireGuardOption{TCP: true,
		Corplink: CorplinkOption{APIServer: "https://example.invalid"}}}
	w.initOk.Store(true)
	if err := w.SetCorplinkNativeActive(false); err != nil {
		t.Fatal(err)
	}
	if dev.downs != 1 || w.device != dev || w.closed.Load() {
		t.Fatal("hard stop must stop peer timers without disposing the reusable device")
	}
	if err := w.SetCorplinkNativeActive(true); !errors.Is(err, ErrCorplinkNativeNotReady) || dev.ups != 0 {
		t.Fatal("native-unready start resumed peers")
	}
	allowed = true
	if err := w.SetCorplinkNativeActive(true); err != nil {
		t.Fatal(err)
	}
	if dev.ups != 1 || w.device != dev {
		t.Fatal("resume replaced device or did not restart peers")
	}
	if err := w.SetCorplinkNativeActive(true); err != nil || dev.ups != 1 {
		t.Fatal("resume not idempotent")
	}
}

func TestCorplinkNativeStopDoesNotTouchOrdinaryWireGuard(t *testing.T) {
	dev := &nativeLifecycleDevice{}
	w := &WireGuard{device: dev, option: WireGuardOption{TCP: true}}
	if err := w.SetCorplinkNativeActive(false); err != nil || dev.downs != 0 {
		t.Fatal("airport WireGuard was stopped")
	}
}

func TestCorplinkCannotCreatePeerTimersWhileNativeStopped(t *testing.T) {
	installNativeGuardTestHook(t, func() bool { return false })
	w := &WireGuard{option: WireGuardOption{TCP: true,
		Corplink: CorplinkOption{APIServer: "https://example.invalid"}}}
	if err := w.init0(context.Background()); !errors.Is(err, ErrCorplinkNativeNotReady) || w.device != nil {
		t.Fatal("native-stopped node attempted to initialize peer timers")
	}
}

func TestCorplinkRealDeviceCanStopAndResumeSameStack(t *testing.T) {
	installNativeGuardTestHook(t, func() bool { return true })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := &WireGuard{Base: NewBase(BaseOption{Name: "native-lifecycle-test"}), runCtx: ctx, runCancel: cancel,
		option: WireGuardOption{TCP: true, MTU: 1400, PrivateKey: strings.Repeat("11", 32),
			IPStack:             IPStackOption{Mode: ipStackAuto},
			WireGuardPeerOption: WireGuardPeerOption{Server: "127.0.0.1", Port: 9, PublicKey: strings.Repeat("22", 32)},
			Corplink:            CorplinkOption{APIServer: "https://example.invalid"}},
		localPrefixes: []netip.Prefix{netip.MustParsePrefix("10.23.0.2/32")}}
	w.connectAddr = w.option.Addr()
	bind := newTCPWireGuardBind(ctx, func(context.Context) (net.Conn, error) { return nil, errors.New("no business dial in lifecycle test") })
	w.bind = bind
	if err := w.init(ctx); err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	dev, stack := w.device, w.tunDevice
	if err := dev.(interface{ Up() error }).Up(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if err := w.SetCorplinkNativeActive(false); err != nil {
			t.Fatal(err)
		}
		if !bind.closed.Load() {
			t.Fatal("real WG Down left the transport open")
		}
		if err := w.SetCorplinkNativeActive(true); err != nil {
			t.Fatal(err)
		}
		if bind.closed.Load() || w.device != dev || w.tunDevice != stack {
			t.Fatal("real WG Up lost original transport/device/stack")
		}
	}
}

func TestCorplinkRebuildCannotCommitAfterNativeStop(t *testing.T) {
	for _, revoked := range []bool{false, true} {
		installNativeGuardTestHook(t, func() bool { return !revoked })
		old, next := &nativeLifecycleDevice{}, &nativeLifecycleDevice{}
		w := &WireGuard{device: old, nativeSuspended: true,
			option: WireGuardOption{Corplink: CorplinkOption{APIServer: "https://example.invalid"}}}
		replacement := &WireGuard{device: next}
		if err := w.commitCorplinkReplacement(replacement, nil); !errors.Is(err, ErrCorplinkNativeNotReady) {
			t.Fatal("replacement crossed explicit native stop")
		}
		if w.device != old || old.closes != 0 || next.closes != 1 || !replacement.closed.Load() {
			t.Fatal("stop lost original device or left rejected replacement running")
		}
	}
}
