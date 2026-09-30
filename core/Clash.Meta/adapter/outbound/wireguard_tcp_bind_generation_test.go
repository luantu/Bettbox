package outbound

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// Pause only the dialer's return; every socket is an established loopback TCP
// connection, so reset must really close it rather than just forget a mock.
func generationTCPDialer(t *testing.T) (func(context.Context) (net.Conn, error), <-chan net.Conn, string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	peers := make(chan net.Conn, 64)
	var mu sync.Mutex
	var conns []net.Conn
	t.Cleanup(func() {
		_ = ln.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, c := range conns {
			_ = c.Close()
		}
	})
	dial := func(ctx context.Context) (net.Conn, error) {
		c, err := (&net.Dialer{}).DialContext(ctx, "tcp", ln.Addr().String())
		if err != nil {
			return nil, err
		}
		peer, err := ln.Accept()
		if err != nil {
			_ = c.Close()
			return nil, err
		}
		mu.Lock()
		conns = append(conns, c, peer)
		mu.Unlock()
		peers <- peer
		return c, nil
	}
	return dial, peers, ln.Addr().String()
}

type generationDialResult struct {
	state *tcpConnState
	err   error
}

func generationContext(t *testing.T) context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return ctx
}

func generationGetConn(bind *tcpWireGuardBind, key string) <-chan generationDialResult {
	done := make(chan generationDialResult, 1)
	go func() {
		state, err := bind.getConn(stateEndpoint{key: key})
		done <- generationDialResult{state, err}
	}()
	return done
}

func awaitGeneration[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(2 * time.Second):
		t.Fatal("transport operation did not complete")
		var zero T
		return zero
	}
}

func assertGenerationFrame(t *testing.T, bind *tcpWireGuardBind, key string, peer net.Conn) {
	t.Helper()
	want := []byte{4, 0, 0, 0, 42}
	if err := bind.Send([][]byte{want}, stateEndpoint{key: key}); err != nil {
		t.Fatalf("next Send failed: %v", err)
	}
	_ = peer.SetReadDeadline(time.Now().Add(2 * time.Second))
	got, err := readTCPFrame(peer)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("peer frame = %v, %v; want %v", got, err, want)
	}
}

func TestTCPTransportResetRejectsInFlightDial(t *testing.T) {
	for _, failOldDial := range []bool{false, true} {
		name := "late_success"
		if failOldDial {
			name = "late_failure"
		}
		t.Run(name, func(t *testing.T) {
			dial, peers, key := generationTCPDialer(t)
			started, release := make(chan struct{}), make(chan struct{})
			var releaseOnce sync.Once
			defer releaseOnce.Do(func() { close(release) })
			var dials atomic.Int32
			bind := newTCPWireGuardBind(generationContext(t), func(ctx context.Context) (net.Conn, error) {
				c, err := dial(ctx)
				if err != nil {
					return nil, err
				}
				if dials.Add(1) == 1 {
					close(started)
					<-release
					if failOldDial {
						_ = c.Close()
						return nil, syscall.ECONNREFUSED
					}
				}
				return c, nil
			})
			t.Cleanup(func() { _ = bind.Close() })
			old := generationGetConn(bind, key)
			awaitGeneration(t, started)
			oldPeer := awaitGeneration(t, peers)
			bind.ReconnectTransport()
			releaseOnce.Do(func() { close(release) })
			result := awaitGeneration(t, old)
			if result.err == nil || result.state != nil {
				t.Fatal("pre-reset dial resurrected a transport after reset")
			}
			if isTunnelFailure(result.err) {
				t.Fatalf("reset was classified as an endpoint failure: %v", result.err)
			}
			if _, ok := bind.tcpConnMap.Load(key); ok {
				t.Fatal("pre-reset transport was published in the connection map")
			}
			_ = oldPeer.SetReadDeadline(time.Now().Add(2 * time.Second))
			if _, err := oldPeer.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
				t.Fatalf("pre-reset TCP socket was not closed: %v", err)
			}
			if result := awaitGeneration(t, generationGetConn(bind, key)); result.err != nil {
				t.Fatalf("reset poisoned next-generation dialing with backoff: %v", result.err)
			}
			assertGenerationFrame(t, bind, key, awaitGeneration(t, peers))
			if dials.Load() != 2 {
				t.Fatalf("got %d dials, want old + next generation", dials.Load())
			}
		})
	}
}

func TestTCPTransportResetKeepsNextGenerationSingleFlight(t *testing.T) {
	dial, peers, key := generationTCPDialer(t)
	started := []chan struct{}{make(chan struct{}), make(chan struct{})}
	release := []chan struct{}{make(chan struct{}), make(chan struct{})}
	var once [2]sync.Once
	defer func() {
		for i := range release {
			once[i].Do(func() { close(release[i]) })
		}
	}()
	var dials atomic.Int32
	bind := newTCPWireGuardBind(generationContext(t), func(ctx context.Context) (net.Conn, error) {
		i := int(dials.Add(1)) - 1
		c, err := dial(ctx)
		if err == nil && i < 2 {
			close(started[i])
			<-release[i]
		}
		return c, err
	})
	t.Cleanup(func() { _ = bind.Close() })
	old := generationGetConn(bind, key)
	awaitGeneration(t, started[0])
	awaitGeneration(t, peers)
	bind.ReconnectTransport()
	next := generationGetConn(bind, key)
	awaitGeneration(t, started[1]) // New dial must not wait for the old one to return.
	nextPeer := awaitGeneration(t, peers)
	once[0].Do(func() { close(release[0]) })
	if result := awaitGeneration(t, old); result.err == nil || isTunnelFailure(result.err) {
		t.Fatalf("old flight did not return a transient reset: %+v", result)
	}
	var waiters []<-chan generationDialResult
	for i := 0; i < 8; i++ {
		waiters = append(waiters, generationGetConn(bind, key))
	}
	once[1].Do(func() { close(release[1]) })
	want := awaitGeneration(t, next)
	if want.err != nil || want.state == nil {
		t.Fatalf("next-generation dial failed: %+v", want)
	}
	for _, waiter := range waiters {
		if got := awaitGeneration(t, waiter); got.err != nil || got.state != want.state {
			t.Fatalf("same-generation waiter did not share the live socket: %+v", got)
		}
	}
	if dials.Load() != 2 {
		t.Fatalf("old completion disrupted the next flight: %d dials", dials.Load())
	}
	assertGenerationFrame(t, bind, key, nextPeer)
}

// Observing Done identifies the waiter entering its select without sleeps or
// test hooks in production. The dial's timeout context is created beforehand.
type generationWaitContext struct {
	context.Context
	observe atomic.Bool
	waiting chan struct{}
	once    sync.Once
}

func (c *generationWaitContext) Done() <-chan struct{} {
	if c.observe.Load() {
		c.once.Do(func() { close(c.waiting) })
	}
	return c.Context.Done()
}

func TestTCPTransportResetReleasesOldGenerationWaiter(t *testing.T) {
	dial, peers, key := generationTCPDialer(t)
	ctx := &generationWaitContext{Context: generationContext(t), waiting: make(chan struct{})}
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var dials atomic.Int32
	bind := newTCPWireGuardBind(ctx, func(ctx context.Context) (net.Conn, error) {
		c, err := dial(ctx)
		if err == nil && dials.Add(1) == 1 {
			close(started)
			<-release
		}
		return c, err
	})
	t.Cleanup(func() { _ = bind.Close() })
	old := generationGetConn(bind, key)
	awaitGeneration(t, started)
	awaitGeneration(t, peers)
	ctx.observe.Store(true)
	waiter := generationGetConn(bind, key)
	awaitGeneration(t, ctx.waiting)
	bind.ReconnectTransport()
	if got := awaitGeneration(t, waiter); !errors.Is(got.err, errTCPTransportReset) || got.state != nil || isTunnelFailure(got.err) {
		t.Fatalf("old waiter crossed reset or entered endpoint backoff: %+v", got)
	}
	next := awaitGeneration(t, generationGetConn(bind, key))
	if next.err != nil {
		t.Fatal(next.err)
	}
	nextPeer := awaitGeneration(t, peers)
	once.Do(func() { close(release) })
	if got := awaitGeneration(t, old); !errors.Is(got.err, errTCPTransportReset) {
		t.Fatalf("old dial did not report reset: %+v", got)
	}
	assertGenerationFrame(t, bind, key, nextPeer)
}

func TestTCPTransportResetDoesNotAffectOtherBind(t *testing.T) {
	dial, peers, key := generationTCPDialer(t)
	first := newTCPWireGuardBind(generationContext(t), dial)
	other := newTCPWireGuardBind(generationContext(t), dial)
	t.Cleanup(func() { _ = first.Close(); _ = other.Close() })
	if result := awaitGeneration(t, generationGetConn(first, key)); result.err != nil {
		t.Fatal(result.err)
	}
	awaitGeneration(t, peers)
	want := awaitGeneration(t, generationGetConn(other, key))
	if want.err != nil {
		t.Fatal(want.err)
	}
	peer := awaitGeneration(t, peers)
	first.ReconnectTransport()
	if got := awaitGeneration(t, generationGetConn(other, key)); got.err != nil || got.state != want.state {
		t.Fatalf("reset crossed bind boundary: %+v", got)
	}
	assertGenerationFrame(t, other, key, peer)
}

func TestTCPTransportSameGenerationFailureBacksOffWaiters(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	key := ln.Addr().String()
	_ = ln.Close() // A real loopback connection refusal, not a synthetic error.
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var dials atomic.Int32
	bind := newTCPWireGuardBind(generationContext(t), func(ctx context.Context) (net.Conn, error) {
		if dials.Add(1) == 1 {
			close(started)
		}
		<-release
		return (&net.Dialer{}).DialContext(ctx, "tcp", key)
	})
	t.Cleanup(func() { _ = bind.Close() })
	first := generationGetConn(bind, key)
	awaitGeneration(t, started)
	var waiters []<-chan generationDialResult
	for i := 0; i < 8; i++ {
		waiters = append(waiters, generationGetConn(bind, key))
	}
	once.Do(func() { close(release) })
	for _, result := range append(waiters, first) {
		if got := awaitGeneration(t, result); got.err == nil || !isTunnelFailure(got.err) {
			t.Fatalf("endpoint failure lost its backoff classification: %+v", got)
		}
	}
	if dials.Load() != 1 {
		t.Fatalf("failed same-generation flight caused a dial storm: %d", dials.Load())
	}
}
