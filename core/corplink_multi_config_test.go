package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func TestCorplinkOneNodeFailureKeepsOtherNodesAndAirportConfig(t *testing.T) {
	const serverPublic = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	data := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/vpn/ping" {
			_, _ = io.WriteString(w, `{"code":0,"data":"ok"}`)
			return
		}
		_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":{"ip":"10.21.0.2","ip_mask":"32","public_key":%q,"setting":{"vpn_mtu":1400}}}`, serverPublic))
	}))
	defer data.Close()
	_, port, err := net.SplitHostPort(data.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	goodControl := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, fmt.Sprintf(`{"code":0,"data":[{"api_port":%s,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FZ-INT-Node"}]}`, port))
	}))
	defer goodControl.Close()
	badControl := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "private-session-must-not-appear", http.StatusUnauthorized)
	}))
	defer badControl.Close()
	cookiePath := filepath.Join(t.TempDir(), "cookies.txt")
	if err := os.WriteFile(cookiePath, []byte("session=test"), 0o600); err != nil {
		t.Fatal(err)
	}
	privateKey := base64.StdEncoding.EncodeToString(make([]byte, 32))
	newWG := func(name, api string) map[string]any {
		return map[string]any{
			"name": name + "-WG", "type": "wireguard",
			"server": "127.0.0.1", "port": 34080,
			"ip": "0.0.0.0/32", "private-key": privateKey,
			"public-key": serverPublic, "allowed-ips": []string{"0.0.0.0/0"},
			"tcp": true, "udp": true,
			"corplink": map[string]any{
				"corplink-api-server":      api,
				"corplink-cookie-file":     cookiePath,
				"corplink-code":            "JBSWY3DPEHPK3PXP",
				"corplink-vpn-server-name": name,
				"corplink-public-key":      privateKey,
			},
		}
	}
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		{"name": "Airport-A", "type": "socks5", "server": "127.0.0.1", "port": 1080},
		newWG("FZ-INT-Node", goodControl.URL),
		newWG("FUZHOU-NODE-1", badControl.URL),
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "Airport", "type": "select", "proxies": []string{"Airport-A"}},
		{"name": "FZ-INT-Node", "type": "select", "proxies": []string{"FZ-INT-Node-WG"}},
		{"name": "FUZHOU-NODE-1", "type": "select", "proxies": []string{"FUZHOU-NODE-1-WG"}},
	}
	raw.Rule = []string{"MATCH,Airport"}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatalf("one CorpLink failure invalidated the whole profile: %v", err)
	}
	for _, name := range []string{"Airport-A", "Airport", "FZ-INT-Node-WG", "FUZHOU-NODE-1-WG"} {
		if parsed.Proxies[name] == nil {
			t.Fatalf("proxy/group %s missing after isolated failure", name)
		}
	}
}

func TestCorplinkRejectPlaceholderKeepsAllReferenceTypesParsable(t *testing.T) {
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		{"name": "FUZHOU-NODE-1-WG", "type": "reject"},
		{"name": "Airport-A", "type": "socks5", "server": "127.0.0.1", "port": 1080,
			"dialer-proxy": "FUZHOU-NODE-1-WG"},
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "FUZHOU-NODE-1", "type": "select", "proxies": []string{"REJECT"}},
		{"name": "Downloaded-Uses-WG", "type": "select", "proxies": []string{"FUZHOU-NODE-1-WG"}},
	}
	raw.SubRules = map[string][]string{
		"downloaded": {"DOMAIN-SUFFIX,sub.example.com,FUZHOU-NODE-1-WG"},
	}
	raw.Rule = []string{"MATCH,REJECT"}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatalf("reject placeholder did not preserve Profile parsing: %v", err)
	}
	if parsed.Proxies["FUZHOU-NODE-1-WG"] == nil ||
		parsed.Proxies["Airport-A"] == nil ||
		parsed.Proxies["Downloaded-Uses-WG"] == nil {
		t.Fatal("placeholder or ordinary proxy missing after parse")
	}
}
