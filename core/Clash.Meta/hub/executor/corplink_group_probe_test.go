package executor

import (
	"encoding/json"
	"testing"

	"github.com/metacubex/mihomo/config"
)

// A generated select group's probe must survive config parsing and the proxy
// JSON boundary consumed by the Android proxy page.
func TestCorplinkSelectGroupExposesConfiguredProbeURL(t *testing.T) {
	parsed, err := config.Parse([]byte(`
proxies:
  - name: Corp-Node-WG
    type: direct
proxy-groups:
  - name: Corp-Node
    type: select
    proxies: [Corp-Node-WG]
    url: https://internal.example.invalid/probe
rules:
  - MATCH,Corp-Node
`))
	if err != nil {
		t.Fatal(err)
	}
	proxy := parsed.Proxies["Corp-Node"]
	if proxy == nil {
		t.Fatal("configured CorpLink select group missing")
	}
	encoded, err := json.Marshal(proxy)
	if err != nil {
		t.Fatal(err)
	}
	var exposed map[string]any
	if err := json.Unmarshal(encoded, &exposed); err != nil {
		t.Fatal(err)
	}
	if exposed["testUrl"] != "https://internal.example.invalid/probe" {
		t.Fatalf("select group probe not exposed to Android proxy page: %v", exposed["testUrl"])
	}
}
