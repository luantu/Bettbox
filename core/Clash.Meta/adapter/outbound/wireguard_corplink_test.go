package outbound

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
)

func TestConfiguredDoHEndpointMatchesOnlyHTTPSResolver(t *testing.T) {
	servers := []string{"https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"}
	resolver := &C.Metadata{DstIP: netip.MustParseAddr("1.1.1.1"), DstPort: 443}
	if !configuredDoHEndpoint(resolver, servers) {
		t.Fatal("configured DoH endpoint was not recognized")
	}
	otherPort := &C.Metadata{DstIP: netip.MustParseAddr("1.1.1.1"), DstPort: 80}
	if configuredDoHEndpoint(otherPort, servers) {
		t.Fatal("non-DoH port was recognized as a DoH endpoint")
	}
	otherIP := &C.Metadata{DstIP: netip.MustParseAddr("9.9.9.9"), DstPort: 443}
	if configuredDoHEndpoint(otherIP, servers) {
		t.Fatal("unconfigured address was recognized as a DoH endpoint")
	}
}

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

func TestCorplinkVPNNodeListOnlyTCPAndSanitized(t *testing.T) {
	var loginCalls atomic.Int32
	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/login" {
			loginCalls.Add(1)
			http.Error(w, "login must not run during discovery", http.StatusBadRequest)
			return
		}
		if r.URL.Path != "/api/vpn/list" {
			t.Errorf("unexpected discovery path: %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		if !strings.Contains(r.Header.Get("Cookie"), "session=integration-test") {
			t.Error("saved session cookie was not used")
		}
		_, _ = io.WriteString(w, `{"code":0,"data":[`+
			`{"name":"FZ-INT-Node","protocol_mode":1,"ip":"192.0.2.10","api_port":443,"vpn_port":34080},`+
			`{"name":"UDP-NODE","protocol_mode":2,"ip":"192.0.2.11","api_port":443,"vpn_port":34080},`+
			`{"name":"FUZHOU-NODE-1","protocol_mode":1,"ip":"192.0.2.12","api_port":443,"vpn_port":34080}]}`)
	}))
	defer control.Close()

	got, err := ListCorplinkVPNNodes(CorplinkOption{
		APIServer:  control.URL,
		CookieFile: writeCorplinkCookieFile(t),
		DeviceID:   "android-device-id",
		DeviceName: "android-device-name",
	})
	if err != nil {
		t.Fatalf("list TCP nodes: %v", err)
	}
	if len(got) != 2 || got[0].Name != "FZ-INT-Node" || got[0].ProtocolMode != 1 ||
		got[1].Name != "FUZHOU-NODE-1" || got[1].ProtocolMode != 1 {
		t.Fatalf("wrong TCP nodes or server order: %+v", got)
	}
	if loginCalls.Load() != 0 {
		t.Fatal("discovery started another account login")
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "192.0.2.") ||
		strings.Contains(string(encoded), "integration-test") {
		t.Fatal("discovery response exposed endpoint or cookie material")
	}
}

func TestCorplinkVPNNodeListFailureKeepsOnlyStatusCode(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{name: "http", status: http.StatusUnauthorized, body: `{"cookie":"do-not-report"}`, want: "corplink vpn list HTTP 401"},
		{name: "business", status: http.StatusOK, body: `{"code":1234,"message":"do-not-report"}`, want: "corplink vpn list code 1234"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.status)
				_, _ = io.WriteString(w, tt.body)
			}))
			defer control.Close()
			_, err := ListCorplinkVPNNodes(CorplinkOption{
				APIServer:  control.URL,
				CookieFile: writeCorplinkCookieFile(t),
			})
			if err == nil || err.Error() != tt.want {
				t.Fatalf("list error = %v, want %q", err, tt.want)
			}
		})
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

func TestFetchCorplinkWgInfoReportsSafeVpnListErrorCode(t *testing.T) {
	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"code":10220001,"message":"session token=private-value"}`)
	}))
	defer control.Close()

	_, err := fetchCorplinkWgInfo(CorplinkOption{
		APIServer:  control.URL,
		CookieFile: writeCorplinkCookieFile(t),
	})
	if err == nil || !strings.Contains(err.Error(), "corplink vpn list code 10220001") {
		t.Fatalf("expected safe business code, got %v", err)
	}
	if strings.Contains(err.Error(), "private-value") {
		t.Fatalf("server response leaked into diagnostic: %v", err)
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
