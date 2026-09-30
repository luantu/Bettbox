package outbound

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func nativeGuardFixture(t *testing.T, corplink bool) (*WireGuard, *tcpWireGuardBind, *net.TCPListener, string) {
	t.Helper()
	ln, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	w := &WireGuard{Base: NewBase(BaseOption{Name: "native-guard-test"}), option: WireGuardOption{
		TCP:                 true,
		WireGuardPeerOption: WireGuardPeerOption{Server: "127.0.0.1", Port: ln.Addr().(*net.TCPAddr).Port},
	}}
	if corplink {
		w.option.Corplink.APIServer = "https://control.invalid"
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	bind := newTCPWireGuardBind(ctx, w.dialTCPTransport)
	if _, _, err := bind.Open(0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = bind.Close() })
	w.bind = bind
	w.connectAddr = w.option.Addr()
	w.initOk.Store(true) // Exercise business readiness without authentication or a WG peer.
	return w, bind, ln, ln.Addr().String()
}

func installNativeGuardTestHook(t *testing.T, hook func() bool) {
	t.Helper()
	previous := CorplinkTCPTransportReady
	CorplinkTCPTransportReady = hook
	t.Cleanup(func() { CorplinkTCPTransportReady = previous })
}

func acceptNativeGuardPeer(t *testing.T, ln *net.TCPListener) net.Conn {
	t.Helper()
	_ = ln.SetDeadline(time.Now().Add(2 * time.Second))
	peer, err := ln.AcceptTCP()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = peer.Close() })
	return peer
}

func assertNativeGuardFrame(t *testing.T, bind *tcpWireGuardBind, key string, peer net.Conn) {
	t.Helper()
	want := []byte{4, 0, 0, 0, 42}
	if err := bind.Send([][]byte{want}, stateEndpoint{key: key}); err != nil {
		t.Fatal(err)
	}
	_ = peer.SetReadDeadline(time.Now().Add(2 * time.Second))
	got, err := readTCPFrame(peer)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("peer frame = %v, %v; want %v", got, err, want)
	}
}

func TestCorplinkNativeGuardRejectsSocketThenAllowsReady(t *testing.T) {
	var ready atomic.Bool
	installNativeGuardTestHook(t, ready.Load)
	_, bind, ln, key := nativeGuardFixture(t, true)
	for i := 0; i < 4; i++ {
		if state, err := bind.getConn(stateEndpoint{key: key}); state != nil || !errors.Is(err, ErrCorplinkNativeNotReady) {
			t.Fatalf("native admission opened a pre-TUN socket: state=%v err=%v", state != nil, err)
		}
	}
	bind.mu.Lock()
	failures, backoff := bind.failCount[key], bind.backoffRemainingLocked(key)
	bind.mu.Unlock()
	if failures != 0 || backoff != 0 {
		t.Fatalf("native refusal poisoned endpoint backoff: failures=%d remaining=%v", failures, backoff)
	}
	_ = ln.SetDeadline(time.Now().Add(20 * time.Millisecond))
	if peer, err := ln.AcceptTCP(); err == nil {
		_ = peer.Close()
		t.Fatal("server accepted a socket while native admission was false")
	} else if timeout, ok := err.(net.Error); !ok || !timeout.Timeout() {
		t.Fatalf("unexpected listener error: %v", err)
	}
	ready.Store(true)
	state, err := bind.getConn(stateEndpoint{key: key})
	if err != nil || state == nil {
		t.Fatalf("native ready did not permit an immediate retry: %v", err)
	}
	peer := acceptNativeGuardPeer(t, ln)
	assertNativeGuardFrame(t, bind, key, peer)
}

func TestCorplinkNativeGuardScopeAndSibling(t *testing.T) {
	var ready atomic.Bool
	installNativeGuardTestHook(t, ready.Load)
	_, ordinary, ordinaryLn, ordinaryKey := nativeGuardFixture(t, false)
	if state, err := ordinary.getConn(stateEndpoint{key: ordinaryKey}); err != nil || state == nil {
		t.Fatalf("native guard blocked ordinary TCP WireGuard: %v", err)
	}
	assertNativeGuardFrame(t, ordinary, ordinaryKey, acceptNativeGuardPeer(t, ordinaryLn))
	_, sibling, siblingLn, siblingKey := nativeGuardFixture(t, true)
	ready.Store(true)
	want, err := sibling.getConn(stateEndpoint{key: siblingKey})
	if err != nil {
		t.Fatal(err)
	}
	siblingPeer := acceptNativeGuardPeer(t, siblingLn)
	ready.Store(false)
	_, blocked, _, blockedKey := nativeGuardFixture(t, true)
	if _, err := blocked.getConn(stateEndpoint{key: blockedKey}); !errors.Is(err, ErrCorplinkNativeNotReady) {
		t.Fatalf("new CorpLink bind did not reject native refusal: %v", err)
	}
	if got, err := sibling.getConn(stateEndpoint{key: siblingKey}); err != nil || got != want {
		t.Fatalf("another bind's refusal changed the live sibling: %v", err)
	}
	assertNativeGuardFrame(t, sibling, siblingKey, siblingPeer)
}

func TestCorplinkNativeGuardNilPreservesDesktopDial(t *testing.T) {
	installNativeGuardTestHook(t, nil)
	_, bind, ln, key := nativeGuardFixture(t, true)
	if state, err := bind.getConn(stateEndpoint{key: key}); err != nil || state == nil {
		t.Fatalf("nil native hook blocked the desktop transport: %v", err)
	}
	assertNativeGuardFrame(t, bind, key, acceptNativeGuardPeer(t, ln))
}

func TestCorplinkNativeGuardBusinessErrorsDoNotRequestRebuild(t *testing.T) {
	installNativeGuardTestHook(t, func() bool { return false })
	for _, udp := range []bool{false, true} {
		t.Run(strconv.FormatBool(udp), func(t *testing.T) {
			w, bind, _, key := nativeGuardFixture(t, true)
			metadata := &C.Metadata{DstIP: netip.MustParseAddr("192.0.2.1"), DstPort: 443}
			for i := 0; i < 4; i++ {
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				var err error
				if udp {
					_, err = w.ListenPacketContext(ctx, metadata)
				} else {
					_, err = w.DialContext(ctx, metadata)
				}
				cancel()
				if !errors.Is(err, ErrCorplinkNativeNotReady) {
					t.Fatalf("business entry swallowed native admission error: %v", err)
				}
			}
			if w.busyFail.Load() != 0 || w.requiresRebuild.Load() {
				t.Fatalf("native refusal triggered busy recovery: failures=%d rebuild=%t", w.busyFail.Load(), w.requiresRebuild.Load())
			}
			bind.mu.Lock()
			failures := bind.failCount[key]
			bind.mu.Unlock()
			if failures != 0 {
				t.Fatalf("business native refusal entered endpoint backoff: %d", failures)
			}
		})
	}
}

func TestCorplinkNativeGuardWrappedErrorRemainsTransient(t *testing.T) {
	err := fmt.Errorf("tunnel not ready: %w", ErrCorplinkNativeNotReady)
	if isTunnelFailure(err) {
		t.Fatal("wrapped native admission error was classified as a tunnel failure")
	}
}

func TestCorplinkNativeGuardRefusalDoesNotEraseRealEndpointBackoff(t *testing.T) {
	installNativeGuardTestHook(t, func() bool { return false })
	_, bind, _, key := nativeGuardFixture(t, true)
	bind.recordEndpointFailure(key)
	if _, err := bind.getConn(stateEndpoint{key: key}); err == nil || errors.Is(err, ErrCorplinkNativeNotReady) {
		t.Fatalf("native guard erased a real endpoint failure's backoff: %v", err)
	}
	bind.mu.Lock()
	failures := bind.failCount[key]
	bind.mu.Unlock()
	if failures != 1 {
		t.Fatalf("real endpoint failure count changed: %d", failures)
	}
}
