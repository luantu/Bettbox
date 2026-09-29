package outbound

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
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

func TestCorplinkTwoNodesUseSeparateTokensAndKeys(t *testing.T) {
	const serverPublic = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	publicKeys := []string{
		base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", 32))),
		base64.StdEncoding.EncodeToString([]byte(strings.Repeat("b", 32))),
	}
	names := []string{"FZ-INT-Node", "FUZHOU-NODE-1"}
	ips := []string{"10.21.0.2", "10.22.0.3"}
	dnsIPs := []string{"10.21.0.53", "10.22.0.53"}
	var connCalls [2]atomic.Int32
	ports := make([]string, 2)
	for index := range names {
		index := index
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.Contains(r.Header.Get("Cookie"), fmt.Sprintf("vpn-token=node-%d", index)) {
				t.Errorf("node %d received another session token", index)
			}
			if r.URL.Path == "/vpn/ping" {
				_, _ = io.WriteString(w, `{"code":0,"data":"ok"}`)
				return
			}
			if r.URL.Path != "/vpn/conn" {
				t.Errorf("unexpected path for node %d: %s", index, r.URL.Path)
				http.NotFound(w, r)
				return
			}
			connCalls[index].Add(1)
			var request struct {
				PublicKey string `json:"public_key"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil || request.PublicKey != publicKeys[index] {
				t.Errorf("node %d got wrong public key or invalid request: %v", index, err)
			}
			_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":{"ip":%q,"ip_mask":"32","public_key":%q,"setting":{"vpn_mtu":1400,"vpn_dns":%q,"vpn_dns_backup":"","vpn_dns_domain_split":["corp.example.invalid"]}}}`, ips[index], serverPublic, dnsIPs[index]))
		}))
		defer server.Close()
		_, port, err := net.SplitHostPort(server.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		ports[index] = port
	}
	var listCalls atomic.Int32
	control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		index := int(listCalls.Add(1)) - 1
		if index >= len(names) {
			t.Errorf("unexpected extra list call %d", index)
			http.Error(w, "extra list", http.StatusBadRequest)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "vpn-token", Value: fmt.Sprintf("node-%d", index)})
		_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":[`+
			`{"api_port":%s,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FZ-INT-Node"},`+
			`{"api_port":%s,"vpn_port":34081,"ip":"127.0.0.1","protocol_mode":1,"name":"FUZHOU-NODE-1"}]}`,
			ports[0], ports[1]))
	}))
	defer control.Close()
	cookieFile := writeCorplinkCookieFile(t)
	for index, name := range names {
		info, err := fetchCorplinkWgInfo(CorplinkOption{
			APIServer: control.URL, CookieFile: cookieFile,
			VPNServerName: name, PublicKey: publicKeys[index],
			Code: "JBSWY3DPEHPK3PXP", DeviceID: "shared-device",
		})
		if err != nil {
			t.Fatalf("node %s failed: %v", name, err)
		}
		if info.IP != ips[index] || info.Port != 34080+index {
			t.Fatalf("node %s used another tunnel IP or endpoint: %+v", name, info)
		}
		if len(info.DNSAddresses) != 1 || info.DNSAddresses[0].String() != dnsIPs[index] ||
			len(info.DNSDomains) != 1 || info.DNSDomains[0] != "corp.example.invalid" {
			t.Fatalf("node %s did not retain its private DNS metadata", name)
		}
	}
	if listCalls.Load() != 2 {
		t.Fatalf("list calls = %d, want one per node and no second account login", listCalls.Load())
	}
	for index := range connCalls {
		if connCalls[index].Load() != 1 {
			t.Fatalf("node %d /vpn/conn calls = %d, want one", index, connCalls[index].Load())
		}
	}
}

func TestParseCorplinkDNSAddressesRejectsNonLiteralAndUnsafeIP(t *testing.T) {
	for _, value := range []string{
		"dns.example.invalid", "0.0.0.0", "127.0.0.1", "224.0.0.1", "10.0.0.53/path",
	} {
		if _, err := parseCorplinkDNSAddresses(value); err == nil {
			t.Fatalf("accepted invalid VPN DNS input")
		}
	}
	addresses, err := parseCorplinkDNSAddresses("10.0.0.53", "10.0.0.54")
	if err != nil || len(addresses) != 2 || addresses[0].String() != "10.0.0.53" ||
		addresses[1].String() != "10.0.0.54" {
		t.Fatalf("valid primary and backup DNS were not retained")
	}
}

func TestCorplinkVPNConnFailureDoesNotExposeServerMessage(t *testing.T) {
	for _, response := range []struct {
		status int
		body   string
	}{
		{status: http.StatusUnauthorized, body: `{"cookie":"private-session"}`},
		{status: http.StatusOK, body: `{"code":1234,"message":"private-session"}`},
	} {
		data := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/vpn/ping" {
				_, _ = io.WriteString(w, `{"code":0,"data":"ok"}`)
				return
			}
			w.WriteHeader(response.status)
			_, _ = io.WriteString(w, response.body)
		}))
		_, port, err := net.SplitHostPort(data.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		control := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":[{"api_port":%s,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FZ-INT-Node"}]}`, port))
		}))
		_, err = fetchCorplinkWgInfo(CorplinkOption{
			APIServer: control.URL, CookieFile: writeCorplinkCookieFile(t),
			VPNServerName: "FZ-INT-Node", Code: "JBSWY3DPEHPK3PXP",
			PublicKey: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		})
		control.Close()
		data.Close()
		if err == nil || strings.Contains(err.Error(), "private-session") {
			t.Fatalf("unsafe /vpn/conn error: %v", err)
		}
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
