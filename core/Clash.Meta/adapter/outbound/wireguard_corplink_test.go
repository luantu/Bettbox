package outbound

import (
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/dns"
)

func writeCorplinkCookieFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "cookies.txt")
	if err := os.WriteFile(path, []byte("session=integration-test"), 0o600); err != nil {
		t.Fatalf("write cookie fixture: %v", err)
	}
	return path
}

func TestLoadCorplinkCookieReadsRustCookieStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "corplink_cookies.json")
	content := `[{"name":"session","value":"rust-session","domain":"aq.ruijie.com.cn","path":"/"},{"name":"csrf-token","value":"rust-csrf","domain":"aq.ruijie.com.cn","path":"/"}]`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write rust cookie fixture: %v", err)
	}

	csrf, cookieHeader, err := loadCorplinkCookie(path)
	if err != nil {
		t.Fatalf("load Rust CookieStore: %v", err)
	}
	if csrf != "rust-csrf" || !strings.Contains(cookieHeader, "session=rust-session") {
		t.Fatalf("unexpected Rust CookieStore conversion: csrf=%q cookie=%q", csrf, cookieHeader)
	}
}

func TestCorplinkDNSRoutesEveryConfiguredNameServerThroughTunnel(t *testing.T) {
	tunnel := NewDirect()
	servers := []dns.NameServer{
		{Net: "https", Addr: "https://8.8.8.8/dns-query"},
		{Net: "https", Addr: "https://1.1.1.1/dns-query"},
	}

	routed := routeCorplinkDNSThroughTunnel(servers, tunnel)
	if len(routed) != len(servers) {
		t.Fatalf("route changed nameserver count: got %d want %d", len(routed), len(servers))
	}
	for i, server := range routed {
		if server.ProxyAdapter != tunnel {
			t.Fatalf("nameserver %d is not routed through the CorpLink tunnel: %+v", i, server)
		}
	}
}

func TestCorplinkNodeNameMatchesLegacyFuzhouAlias(t *testing.T) {
	if !corplinkNodeNameMatches("FZ-INT-Node", "FUZHOU_INTL_node") {
		t.Fatal("the current FZ-INT-Node name should match the legacy FUZHOU_INTL_node selector")
	}
}

func TestFetchCorplinkWgInfoSelectsNamedTCPNode(t *testing.T) {
	const deviceID = "android-device-id"
	const deviceName = "SG-Node-Android-test"
	data := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie := r.Header.Get("Cookie")
		if !strings.Contains(cookie, "device_id="+deviceID) || !strings.Contains(cookie, "device_name="+deviceName) {
			t.Fatalf("device identity missing from data-plane cookie: %q", cookie)
		}
		if r.URL.Path == "/vpn/ping" {
			_, _ = io.WriteString(w, `{"code":0,"data":"ok"}`)
			return
		}
		if r.URL.Path != "/vpn/conn" || r.Method != http.MethodPost {
			t.Fatalf("unexpected data-plane request: %s %s", r.Method, r.URL.Path)
		}
		_, _ = io.WriteString(w, `{"code":0,"data":{"ip":"10.113.65.196","ipv6":"","ip_mask":"24","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","setting":{"vpn_mtu":1400}}}`)
	}))
	defer data.Close()
	_, port, _ := net.SplitHostPort(data.Listener.Addr().String())

	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/vpn/list" {
			t.Fatalf("unexpected control-plane request: %s", r.URL.Path)
		}
		cookie := r.Header.Get("Cookie")
		if !strings.Contains(cookie, "device_id="+deviceID) || !strings.Contains(cookie, "device_name="+deviceName) {
			t.Fatalf("device identity missing from control-plane cookie: %q", cookie)
		}
		_, _ = io.WriteString(w, `{"code":0,"data":[{"api_port":`+port+`,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FUZHOU_INTL_node"}]}`)
	}))
	defer control.Close()

	// The test server uses a self-signed certificate; the implementation's
	// transport intentionally mirrors the current Feilian client behavior.
	got, err := fetchCorplinkWgInfo(CorplinkOption{
		APIServer:     control.URL,
		Code:          "JBSWY3DPEHPK3PXP",
		CookieFile:    writeCorplinkCookieFile(t),
		DeviceID:      deviceID,
		DeviceName:    deviceName,
		VPNServerName: "FUZHOU_INTL_node",
		PublicKey:     base64.StdEncoding.EncodeToString(make([]byte, 32)),
	})
	if err != nil {
		t.Fatalf("fetch dynamic WireGuard info: %v", err)
	}
	if got.Server != "127.0.0.1" || got.Port != 34080 || got.IP != "10.113.65.196" || got.IPMask != "24" || got.MTU != 1400 {
		t.Fatalf("unexpected dynamic info: %+v", got)
	}
}

func TestCorplinkTCPDialTargetTracksRefreshedEndpoint(t *testing.T) {
	w := &WireGuard{option: WireGuardOption{
		WireGuardPeerOption: WireGuardPeerOption{
			Server: "initial.example.test",
			Port:   34080,
		},
	}}
	if got := w.tcpDialTarget(); got != "initial.example.test:34080" {
		t.Fatalf("unexpected initial TCP target: %q", got)
	}

	// refreshCorplinkOption updates the live option after /vpn/conn selects
	// the actual FUZHOU_INTL_node endpoint.
	w.option.Server = "198.51.100.27"
	w.option.Port = 35555
	if got := w.tcpDialTarget(); got != "198.51.100.27:35555" {
		t.Fatalf("TCP target did not follow refreshed endpoint: %q", got)
	}
}
