package outbound

import (
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFetchCorplinkWgInfoSelectsNamedTCPNode(t *testing.T) {
	data := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		_, _ = io.WriteString(w, `{"code":0,"data":[{"api_port":`+port+`,"vpn_port":34080,"ip":"127.0.0.1","protocol_mode":1,"name":"FUZHOU_INTL_node"}]}`)
	}))
	defer control.Close()

	// The test server uses a self-signed certificate; the implementation's
	// transport intentionally mirrors the current Feilian client behavior.
	got, err := fetchCorplinkWgInfo(CorplinkOption{
		APIServer:     control.URL,
		Code:          "JBSWY3DPEHPK3PXP",
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
