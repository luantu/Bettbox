package outbound

import (
	"context"
	"net"
	"strconv"
	"testing"
	"time"
)

func TestCorplinkControlDialReusesKnownPhysicalAddress(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			conn.Close()
		}
	}()

	cache := newCorplinkAddressCache(time.Minute)
	port := strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	firstHost := net.JoinHostPort("localhost", port)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := cache.dial(ctx, "tcp", firstHost, nil)
	if err != nil {
		t.Fatalf("initial control dial: %v", err)
	}
	conn.Close()
	if got, ok := cache.lookup(firstHost); !ok || got != net.JoinHostPort("127.0.0.1", port) {
		t.Fatalf("cached address = %q, valid=%v", got, ok)
	}

	// This hostname cannot resolve. Reaching the same listener proves that a
	// subsequent protected control-plane dial can use the last known address
	// without asking Android's VPN DNS resolver for the management hostname.
	secondHost := net.JoinHostPort("unresolvable.invalid", port)
	cache.store(secondHost, net.JoinHostPort("127.0.0.1", port))
	conn, err = cache.dial(ctx, "tcp", secondHost, nil)
	if err != nil {
		t.Fatalf("cached control dial: %v", err)
	}
	conn.Close()
}

func TestCorplinkControlDialNeverCachesFakeIP(t *testing.T) {
	cache := newCorplinkAddressCache(time.Minute)
	address := "management.example:10443"
	cache.store(address, "198.18.0.7:10443")
	if cached, ok := cache.lookup(address); ok {
		t.Fatalf("fake IP must not be cached: %s", cached)
	}
	cache.store(address, "198.19.255.1:10443")
	if cached, ok := cache.lookup(address); ok {
		t.Fatalf("fake IP must not be cached: %s", cached)
	}
	cache.store(address, "10.0.2.16:10443")
	if cached, ok := cache.lookup(address); !ok || cached != "10.0.2.16:10443" {
		t.Fatalf("real address was not cached: %q valid=%v", cached, ok)
	}
}

func TestCorplinkControlIPSeedsPhysicalAddress(t *testing.T) {
	cache := newCorplinkAddressCache(time.Minute)
	base := "https://management.example:10443"
	primeCorplinkControlAddress(cache, base, "203.0.113.8")
	if got, ok := cache.lookup("management.example:10443"); !ok || got != "203.0.113.8:10443" {
		t.Fatalf("physical control address = %q, valid=%v", got, ok)
	}
	primeCorplinkControlAddress(cache, base, "198.18.0.8")
	if got, _ := cache.lookup("management.example:10443"); got != "203.0.113.8:10443" {
		t.Fatalf("fake IP replaced known physical address: %q", got)
	}
}
