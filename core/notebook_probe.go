package main

import (
	"context"
	"encoding/json"
	"net"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
)

const notebookTimeout = 3500 * time.Millisecond

type notebookVerdict string

const (
	notebookUnknown     notebookVerdict = "unknown"
	notebookAvailable   notebookVerdict = "available"
	notebookUnavailable notebookVerdict = "unavailable"
)

type notebookIdentity struct {
	Name string `json:"name"`
	Type string `json:"type"`
	ID   string `json:"id"`
}

func notebookProxyIdentity(proxy C.Proxy) notebookIdentity {
	identity := notebookIdentity{Name: proxy.Name(), Type: proxy.Type().String()}
	outbound := proxy.Adapter()
	if stable, ok := outbound.(interface{ Id() string }); ok {
		identity.ID = strings.TrimSpace(stable.Id())
		return identity
	}
	// The parser wraps leaf adapters in AutoCloseProxyAdapter. The wrapper
	// keeps the underlying adapter's JSON ID, but hides methods outside the interface.
	if data, err := outbound.MarshalJSON(); err == nil {
		var fields struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(data, &fields) == nil {
			identity.ID = strings.TrimSpace(fields.ID)
		}
	}
	return identity
}

func notebookLeaf(identity notebookIdentity) bool {
	if identity.ID == "" {
		return false
	}
	switch strings.ToLower(identity.Type) {
	case "shadowsocks", "shadowsocksr", "socks5", "http", "vmess", "vless", "trojan", "snell", "mieru", "hysteria", "hysteria2", "tuic", "wireguard", "ssh", "anytls", "sudoku", "trusttunnel", "shadowquic":
		return true
	default:
		return false
	}
}

type notebookObservation struct {
	Time  time.Time
	Alive bool
	Delay uint16
}

func notebookURLHistory(proxy C.Proxy) notebookObservation {
	history := proxy.ExtraDelayHistories()[adapter.NotebookProbeURL]
	if len(history.History) == 0 {
		return notebookObservation{}
	}
	last := history.History[len(history.History)-1]
	return notebookObservation{last.Time, history.Alive, last.Delay}
}

// The delay returned by URLTest can be positive even when StatusCode did not
// match. Only a new, attributable sample in the per-URL history counts.
func runNotebookHistory(before notebookObservation, test func(uint16) (notebookObservation, bool), now func() time.Time) (notebookVerdict, uint16) {
	observe := func(expected uint16) (notebookObservation, bool) {
		sample, ok := test(expected)
		valid := ok && !sample.Time.IsZero() && sample.Time.After(before.Time) && !sample.Time.After(now())
		before = sample
		return sample, valid
	}
	negative, fresh := observe(599)
	if !fresh || negative.Alive || negative.Delay != 0 {
		return notebookUnknown, 0
	}
	for range 2 {
		positive, fresh := observe(200)
		if !fresh {
			return notebookUnknown, 0
		}
		if positive.Alive && positive.Delay > 0 && positive.Delay < 65535 {
			return notebookAvailable, positive.Delay
		}
		if positive.Alive || positive.Delay != 0 {
			return notebookUnknown, 0
		}
	}
	return notebookUnavailable, 0
}

type notebookRecord struct {
	Identity    notebookIdentity `json:"identity"`
	CheckedAt   time.Time        `json:"checkedAt"`
	Verdict     notebookVerdict  `json:"verdict"`
	Delay       uint16           `json:"delay,omitempty"`
	Unsupported bool             `json:"unsupported,omitempty"`
}

func (record notebookRecord) valid(identity notebookIdentity, now time.Time, maxAge time.Duration) bool {
	age := now.Sub(record.CheckedAt)
	return identity.ID != "" && record.Identity == identity && !record.CheckedAt.IsZero() && age >= 0 && age <= maxAge
}

func probeNotebook(ctx context.Context, proxy C.Proxy, identity notebookIdentity) notebookRecord {
	result := notebookRecord{Identity: identity, Verdict: notebookUnknown}
	outbound, ok := proxy.(*adapter.Proxy)
	if ok && notebookLeaf(identity) && ctx.Err() == nil {
		outbound.WithNotebookTests(func(test func(context.Context, utils.IntRanges[uint16]) (uint16, error)) {
			result.Verdict, result.Delay = runNotebookHistory(notebookURLHistory(proxy), func(expected uint16) (notebookObservation, bool) {
				if ctx.Err() != nil {
					return notebookObservation{}, false
				}
				ranges, _ := utils.NewUnsignedRanges[uint16](strconv.Itoa(int(expected)))
				request, cancel := context.WithTimeout(ctx, notebookTimeout)
				defer cancel()
				_, _ = test(request, ranges)
				sample := notebookURLHistory(proxy)
				return sample, request.Err() == nil && notebookProxyIdentity(proxy) == identity
			}, time.Now)
		})
		if result.Verdict != notebookUnknown && ctx.Err() == nil {
			result.Unsupported = notebookBusinessUnsupported(ctx, proxy)
		}
	}
	result.CheckedAt = time.Now()
	return result
}

// Keep the HEAD health signal and the unauthenticated browser-style comparison
// distinct. Only the explicit unsupported marker is calibrated here.
func notebookBusinessUnsupported(ctx context.Context, proxy C.Proxy) bool {
	ctx, cancel := context.WithTimeout(ctx, notebookTimeout)
	defer cancel()
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return false
	}
	transport := &http.Transport{
		TLSClientConfig: tlsConfig,
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			dstPort, err := strconv.ParseUint(port, 10, 16)
			if err != nil {
				return nil, err
			}
			return proxy.DialContext(ctx, &C.Metadata{NetWork: C.TCP, Host: host, DstPort: uint16(dstPort)})
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 8 || !notebookRedirectAllowed(req.URL) {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, adapter.NotebookProbeURL, nil)
	if err != nil {
		return false
	}
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	response.Body.Close()
	return notebookFinalUnsupported(response.Request.URL, response.StatusCode)
}

func notebookFinalUnsupported(location *url.URL, status int) bool {
	return notebookRedirectAllowed(location) && (status < 300 || status >= 400) &&
		slices.Contains(location.Query()["location"], "unsupported")
}

func notebookRedirectAllowed(target *url.URL) bool {
	host := strings.ToLower(target.Hostname())
	return target.Scheme == "https" && (target.Port() == "" || target.Port() == "443") &&
		(host == "google.com" || strings.HasSuffix(host, ".google.com") ||
			host == "notebooklm.google" || host == "notebook.google")
}
