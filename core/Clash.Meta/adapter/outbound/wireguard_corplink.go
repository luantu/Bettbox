package outbound

// corplink (锐捷 CorpLink VPN) 的认证与对端信息获取。
// 复用 corplink 客户端的 /vpn/conn API：用 TOTP + cookie 换取当前会话
// 分配的隧道 IP 与服务器公钥，使 wireguard 节点无需外部客户端即可独立建立隧道。

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"crypto/tls"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/log"
)

// corplinkWGIdentifier 是 CorpLink 版 wireguard-go 使用的 Noise 构造标识符。
// 标准 WireGuard 是 "WireGuard v1 zx2c4 Jason@zx2c4.com"；CorpLink 服务端
// 用 "CorpLink v1 vpn@feilian-----------" 计算 InitialHash/InitialChainKey，
// 客户端必须使用同一个标识符，否则服务端无法解密握手 initiation（表现为
// TCP 已建立但握手永不完成 / 节点测速 timeout）。
const corplinkWGIdentifier = "CorpLink v1 vpn@feilian-----------"

type corplinkCachedAddress struct {
	dialAddress string
	expiresAt   time.Time
}

// Android's VpnService.protect applies to the connected socket, not the DNS
// lookup that net.Dialer performs first. During a VPN reconfiguration Android
// may resolve the management hostname through the local fake-IP DNS server.
// Keep the physical address from a successful pre-VPN control connection in
// memory, so later protected management requests do not depend on that DNS.
type corplinkAddressCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	entries map[string]corplinkCachedAddress
}

var corplinkControlAddresses = newCorplinkAddressCache(30 * time.Minute)

func newCorplinkAddressCache(ttl time.Duration) *corplinkAddressCache {
	return &corplinkAddressCache{ttl: ttl, entries: make(map[string]corplinkCachedAddress)}
}

func (c *corplinkAddressCache) lookup(address string) (string, bool) {
	c.mu.RLock()
	entry, ok := c.entries[address]
	c.mu.RUnlock()
	return entry.dialAddress, ok && time.Now().Before(entry.expiresAt)
}

func (c *corplinkAddressCache) store(address, dialAddress string) {
	host, port, err := net.SplitHostPort(address)
	if err != nil || net.ParseIP(host) != nil {
		return // Literal-IP node endpoints need no bootstrap DNS cache.
	}
	ip, dialPort, err := net.SplitHostPort(dialAddress)
	if err != nil || port != dialPort || net.ParseIP(ip) == nil {
		return
	}
	// A fake IP is only meaningful inside mihomo's local resolver. Using it
	// for a protected physical socket would reproduce the VPN self-loop.
	if parsed := net.ParseIP(ip).To4(); parsed != nil && parsed[0] == 198 && (parsed[1] == 18 || parsed[1] == 19) {
		return
	}
	c.mu.Lock()
	c.entries[address] = corplinkCachedAddress{dialAddress: dialAddress, expiresAt: time.Now().Add(c.ttl)}
	c.mu.Unlock()
}

// primeCorplinkControlAddress accepts an address resolved on Android's
// physical Network, never an IP supplied by the user or by VPN DNS.
func primeCorplinkControlAddress(c *corplinkAddressCache, baseURL, physicalIP string) {
	if net.ParseIP(physicalIP) == nil {
		return
	}
	u, err := url.Parse(baseURL)
	if err != nil || u.Hostname() == "" || u.Scheme != "https" {
		return
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	c.store(net.JoinHostPort(u.Hostname(), port), net.JoinHostPort(physicalIP, port))
}

func (c *corplinkAddressCache) dial(ctx context.Context, network, address string, hook dialer.SocketControl) (net.Conn, error) {
	d := net.Dialer{Timeout: 5 * time.Second}
	if hook != nil {
		d.ControlContext = func(_ context.Context, nw, addr string, socket syscall.RawConn) error {
			return hook(nw, addr, socket)
		}
	}
	if cached, ok := c.lookup(address); ok {
		if conn, err := d.DialContext(ctx, network, cached); err == nil {
			c.store(address, cached) // Extend only after a successful physical dial.
			return conn, nil
		}
	}
	conn, err := d.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}
	c.store(address, conn.RemoteAddr().String())
	return conn, nil
}

// CorplinkOption 描述 corplink 认证所需参数。
type CorplinkOption struct {
	// APIServer 为 corplink 控制面地址（如 https://140.224.74.169:34443），
	// 用于调用 /vpn/conn 获取会话信息。为空时不做认证。
	APIServer string `proxy:"corplink-api-server,omitempty"`
	// ControlIP is the management hostname resolved on Android's underlying
	// physical Network. It is optional; the last successful address is the
	// fallback while no physical network is available.
	ControlIP string `proxy:"corplink-control-ip,omitempty"`
	// Code 为 base32 编码的 TOTP 密钥（corplink config.json 的 code 字段）。
	Code string `proxy:"corplink-code,omitempty"`
	// CookieFile 为 corplink 保存的 cookie 文件路径（utun16_cookies.json）。
	CookieFile string `proxy:"corplink-cookie-file,omitempty"`
	// DeviceID and DeviceName identify this client separately from other
	// devices using the same account.
	DeviceID   string `proxy:"corplink-device-id,omitempty"`
	DeviceName string `proxy:"corplink-device-name,omitempty"`
	// VPNServerName selects the company VPN node returned by /api/vpn/list.
	VPNServerName string `proxy:"corplink-vpn-server-name,omitempty"`
	// UseVPNDNS makes this node use only the private DNS returned by its own
	// /vpn/conn session. A missing or public server address fails this node.
	UseVPNDNS bool `proxy:"corplink-use-vpn-dns,omitempty"`
	// HealthHost is a device-local, HTTPS-only hostname to resolve through
	// this node's private DNS. It must never appear in logs.
	HealthHost string `proxy:"corplink-health-host,omitempty"`
	// PublicKey 为本机 wireguard 公钥（base64），用于 /vpn/conn 请求。
	PublicKey string `proxy:"corplink-public-key,omitempty"`
	// RefreshCommand 为刷新 cookie 的可执行命令。
	// 当检测到 cookie 即将过期时，mihomo-sg 会执行该命令刷新会话。
	// 对应 corplink-rs 的 --refresh-cookie 模式，例如：
	//   macos:   /Users/xx/corplink --refresh-cookie /Users/xx/config.json
	//   windows: C:\corplink\corplink.exe --refresh-cookie C:\corplink\config.json
	RefreshCommand string `proxy:"corplink-refresh-command,omitempty"`
	// RefreshThresholdHours 为提前刷新的阈值（小时）。cookie 剩余有效期
	// 小于该值时触发刷新。默认 48（提前 2 天）。
	RefreshThresholdHours int `proxy:"corplink-refresh-threshold-hours,omitempty"`
	// RefreshHour 为每日允许执行刷新的小时（0-23，本地时区）。
	// 目的是把刷新动作集中到低谷时段（如凌晨）。默认 3（凌晨 3 点）。
	// 若 cookie 剩余有效期已不足 1 小时，则忽略该限制立即刷新。
	RefreshHour int `proxy:"corplink-refresh-hour,omitempty"`
}

type corplinkRespWgInfo struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    *struct {
		IP        string `json:"ip"`
		IPv6      string `json:"ipv6"`
		IPMask    string `json:"ip_mask"`
		Mode      int    `json:"mode"`
		PublicKey string `json:"public_key"`
		Setting   *struct {
			VPNMTU            int      `json:"vpn_mtu"`
			VPNDNS            string   `json:"vpn_dns"`
			VPNDNSBackup      string   `json:"vpn_dns_backup"`
			VPNDNSDomainSplit []string `json:"vpn_dns_domain_split"`
		} `json:"setting"`
	} `json:"data"`
}

type corplinkWgInfo struct {
	IP              string
	IPMask          string
	IPv6            string
	ServerPubKey    string
	ServerPubKeyHex string
	MTU             int
	Server          string
	Port            int
	DNSAddresses    []netip.Addr
	DNSDomains      []string
}

func applyCorplinkInternalDNS(option *WireGuardOption, info *corplinkWgInfo) error {
	if !option.Corplink.UseVPNDNS {
		return nil
	}
	if info == nil || len(info.DNSAddresses) == 0 {
		return errors.New("corplink private VPN DNS unavailable")
	}
	for _, address := range info.DNSAddresses {
		if !address.IsValid() || !address.IsPrivate() {
			return errors.New("corplink private VPN DNS invalid")
		}
	}
	option.corplinkDNS = append([]netip.Addr(nil), info.DNSAddresses...)
	option.corplinkDNSDomains = append([]string(nil), info.DNSDomains...)
	return nil
}

func parseCorplinkDNSAddresses(values ...string) ([]netip.Addr, error) {
	addresses := make([]netip.Addr, 0, len(values))
	for _, value := range values {
		for _, item := range strings.FieldsFunc(value, func(r rune) bool {
			return r == ',' || r == ';' || r == ' ' || r == '\t' || r == '\n'
		}) {
			address, err := netip.ParseAddr(item)
			if err != nil || !address.IsValid() || address.IsUnspecified() ||
				address.IsLoopback() || address.IsMulticast() || address.IsLinkLocalUnicast() {
				return nil, errors.New("corplink vpn DNS address invalid")
			}
			address = address.Unmap()
			if !slices.Contains(addresses, address) {
				addresses = append(addresses, address)
			}
		}
	}
	return addresses, nil
}

func normalizeCorplinkDNSDomains(values []string) ([]string, error) {
	domains := make([]string, 0, len(values))
	for _, raw := range values {
		domain := strings.ToLower(strings.Trim(strings.TrimSpace(raw), "."))
		domain = strings.TrimPrefix(domain, "*.")
		if len(domain) == 0 || len(domain) > 253 {
			return nil, errors.New("corplink vpn DNS domain invalid")
		}
		for _, label := range strings.Split(domain, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return nil, errors.New("corplink vpn DNS domain invalid")
			}
			for _, char := range label {
				if !(char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '-') {
					return nil, errors.New("corplink vpn DNS domain invalid")
				}
			}
		}
		if !slices.Contains(domains, domain) {
			domains = append(domains, domain)
		}
	}
	return domains, nil
}

type corplinkVPNNode struct {
	APIPort      int      `json:"api_port"`
	VPNPort      int      `json:"vpn_port"`
	IP           string   `json:"ip"`
	ProtocolMode int      `json:"protocol_mode"`
	Name         string   `json:"name"`
	BackupIPs    []string `json:"backup_ips"`
}

type corplinkEnvelope[T any] struct {
	Code int `json:"code"`
	Data T   `json:"data"`
}

// CorplinkVPNNodeSummary is the only server-list information exposed to the UI.
// Endpoint addresses and session cookies stay inside the control-plane client.
type CorplinkVPNNodeSummary struct {
	Name         string `json:"name"`
	ProtocolMode int    `json:"protocolMode"`
}

func corplinkNodeNameMatches(candidate, requested string) bool {
	candidate = strings.ToLower(strings.TrimSpace(candidate))
	requested = strings.ToLower(strings.TrimSpace(requested))
	if candidate == requested {
		return true
	}
	// The Feilian control plane has used several spellings for the same
	// Fuzhou international TCP node. Compare a punctuation-free form so that
	// FZ-INT-Node, FZ_INT_Node and FUZHOU_INTL_node remain interchangeable.
	canonical := func(value string) string {
		var b strings.Builder
		for _, r := range value {
			if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
				b.WriteRune(r)
			}
		}
		return b.String()
	}
	left, right := canonical(candidate), canonical(requested)
	if (left == "fzintnode" || left == "fuzhouintlnode") &&
		(right == "fzintnode" || right == "fuzhouintlnode") {
		return true
	}
	return false
}

type corplinkControlSession struct {
	base           string
	client         *http.Client
	jar            *cookiejar.Jar
	controlCookies []*http.Cookie
	csrf           string
	cookieHeader   string
}

func newCorplinkControlSession(opt CorplinkOption) (*corplinkControlSession, error) {
	if opt.APIServer == "" {
		return nil, errors.New("corplink api server not set")
	}

	csrf, cookieStr, err := loadCorplinkCookie(opt.CookieFile)
	if err != nil {
		return nil, err
	}

	base := strings.TrimSuffix(opt.APIServer, "/")
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 15 * time.Second, Jar: jar}
	transport := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	// Android: the CorpLink control-plane calls (/api/vpn/list, /vpn/ping,
	// /vpn/conn) must bypass the local VpnService, otherwise they are
	// captured by tun0 and routed back through the proxy (which, when the
	// proxy is SG-Node itself, is a self-loop -> refresh EOF / auth fails).
	// dialer.DefaultSocketHook is VpnService.protect on Android and nil on
	// other platforms, so this is a no-op outside Android.
	if hook := dialer.DefaultSocketHook; hook != nil {
		primeCorplinkControlAddress(corplinkControlAddresses, base, opt.ControlIP)
		transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
			return corplinkControlAddresses.dial(ctx, network, address, hook)
		}
	}
	client.Transport = transport
	controlURL, err := url.Parse(base)
	if err != nil || controlURL.Host == "" {
		return nil, errors.New("corplink control server invalid")
	}
	controlCookies := parseCorplinkCookies(cookieStr)
	if opt.DeviceID != "" {
		controlCookies = append(controlCookies, &http.Cookie{Name: "device_id", Value: opt.DeviceID})
	}
	if opt.DeviceName != "" {
		controlCookies = append(controlCookies, &http.Cookie{Name: "device_name", Value: opt.DeviceName})
	}
	jar.SetCookies(controlURL, controlCookies)
	// Keep the serialized Cookie header explicitly, matching the reference
	// corplink client. The jar is still used for Set-Cookie persistence, but
	// relying on domain matching alone can drop the control-session cookies
	// after the API base switches to a node IP.
	return &corplinkControlSession{
		base:           base,
		client:         client,
		jar:            jar,
		controlCookies: controlCookies,
		csrf:           csrf,
		cookieHeader:   appendCorplinkCookie(appendCorplinkCookie(cookieStr, "device_id", opt.DeviceID), "device_name", opt.DeviceName),
	}, nil
}

func (s *corplinkControlSession) request(method, endpoint string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequest(method, endpoint, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	// The Feilian control plane validates this Android CorpLink identity.
	req.Header.Set("User-Agent", "CorpLink/201000 (GooglePixel; Android 16; en)")
	req.Header.Set("Accept", "application/json")
	if s.cookieHeader != "" {
		req.Header.Set("Cookie", s.cookieHeader)
	}
	if s.csrf != "" {
		req.Header.Set("csrf-token", s.csrf)
	}
	return s.client.Do(req)
}

func (s *corplinkControlSession) listVPNNodes() ([]corplinkVPNNode, error) {
	var nodes corplinkEnvelope[[]corplinkVPNNode]
	listResp, err := s.request(http.MethodGet, s.base+"/api/vpn/list?os=Android&os_version=2", nil)
	if err != nil {
		return nil, err
	}
	listBody, readErr := io.ReadAll(io.LimitReader(listResp.Body, 2<<20))
	listResp.Body.Close()
	if readErr != nil {
		return nil, readErr
	}
	if listResp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("corplink vpn list HTTP %d", listResp.StatusCode)
	}
	if err := json.Unmarshal(listBody, &nodes); err != nil {
		return nil, errors.New("corplink vpn list invalid response")
	}
	if nodes.Code != 0 {
		// The server message may contain account or session material. Only the
		// numeric business code is safe to forward into Android logs.
		return nil, fmt.Errorf("corplink vpn list code %d", nodes.Code)
	}
	// The Feilian control plane signs a vpn-token (Set-Cookie on /api/vpn/list)
	// that the VPN node requires on /vpn/conn. It carries uid/did(device_id)/
	// session_id. Without it the node answers 10220001 "Cookies are missing".
	// Capture it and attach to the per-request Cookie header used for ping/conn.
	for _, sc := range listResp.Header.Values("Set-Cookie") {
		if v := extractCorplinkCookie(sc, "vpn-token"); v != "" {
			s.cookieHeader = appendCorplinkCookie(s.cookieHeader, "vpn-token", v)
		}
	}
	return nodes.Data, nil
}

// ListCorplinkVPNNodes discovers TCP-capable names without initiating another
// login or connecting to any data-plane server.
func ListCorplinkVPNNodes(opt CorplinkOption) ([]CorplinkVPNNodeSummary, error) {
	session, err := newCorplinkControlSession(opt)
	if err != nil {
		return nil, err
	}
	defer session.client.CloseIdleConnections()
	nodes, err := session.listVPNNodes()
	if err != nil {
		return nil, err
	}
	seen := make(map[string]struct{}, len(nodes))
	summaries := make([]CorplinkVPNNodeSummary, 0, len(nodes))
	for _, node := range nodes {
		name := strings.TrimSpace(node.Name)
		if node.ProtocolMode != 1 || name == "" {
			continue
		}
		if _, exists := seen[name]; exists {
			continue
		}
		seen[name] = struct{}{}
		summaries = append(summaries, CorplinkVPNNodeSummary{Name: name, ProtocolMode: node.ProtocolMode})
	}
	return summaries, nil
}

// fetchCorplinkWgInfo 调用 corplink /vpn/conn API 获取当前会话的 wg 信息。
func fetchCorplinkWgInfo(opt CorplinkOption) (*corplinkWgInfo, error) {
	session, err := newCorplinkControlSession(opt)
	if err != nil {
		return nil, err
	}
	defer session.client.CloseIdleConnections()
	nodeList, err := session.listVPNNodes()
	if err != nil {
		return nil, err
	}
	var node *corplinkVPNNode
	for i := range nodeList {
		candidate := &nodeList[i]
		if corplinkNodeNameMatches(candidate.Name, opt.VPNServerName) && candidate.ProtocolMode == 1 {
			node = candidate
			break
		}
	}
	if node == nil && opt.VPNServerName == "" {
		for i := range nodeList {
			if nodeList[i].ProtocolMode == 1 {
				node = &nodeList[i]
				break
			}
		}
	}
	if node == nil {
		available := make([]string, 0, len(nodeList))
		for _, candidate := range nodeList {
			available = append(available, fmt.Sprintf("%s(protocol_mode=%d)", candidate.Name, candidate.ProtocolMode))
		}
		return nil, fmt.Errorf("corplink vpn node %q not found or not TCP; available: %s", opt.VPNServerName, strings.Join(available, ", "))
	}
	var dataBase string
	var serverTime time.Time
	for _, ip := range append([]string{node.IP}, node.BackupIPs...) {
		if net.ParseIP(ip) == nil || node.APIPort <= 0 {
			continue
		}
		candidate := "https://" + net.JoinHostPort(ip, strconv.Itoa(node.APIPort))
		if nodeURL, parseErr := url.Parse(candidate); parseErr == nil {
			// Match corplink-rs: cookies received on the control hostname are
			// copied into the selected node's host scope before ping/conn.
			session.jar.SetCookies(nodeURL, session.controlCookies)
		}
		pingResp, pingErr := session.request(http.MethodGet, candidate+"/vpn/ping?os=Android&os_version=2", nil)
		if pingErr == nil {
			raw, _ := io.ReadAll(io.LimitReader(pingResp.Body, 64<<10))
			pingResp.Body.Close()
			var ping corplinkEnvelope[json.RawMessage]
			if pingResp.StatusCode == http.StatusOK && json.Unmarshal(raw, &ping) == nil && ping.Code == 0 {
				dataBase = candidate
				node.IP = ip
				if dateHeader := pingResp.Header.Get("Date"); dateHeader != "" {
					if parsed, parseErr := http.ParseTime(dateHeader); parseErr == nil {
						serverTime = parsed
					}
				}
				break
			}
		}
	}
	if dataBase == "" {
		return nil, fmt.Errorf("corplink vpn node %q is unreachable", node.Name)
	}
	apiURL := dataBase + "/vpn/conn?os=Android&os_version=2"
	// corplink /vpn/conn 的 public_key 字段期望 base64 编码；
	// 兼容 hex 输入（option.PublicKey 在 NewWireGuard 中已被统一为 hex）。
	reqPubKey := opt.PublicKey
	if b, err := hex.DecodeString(reqPubKey); err == nil && len(b) == 32 {
		reqPubKey = base64.StdEncoding.EncodeToString(b)
	}
	if serverTime.IsZero() {
		serverTime = time.Now()
	}
	body, _ := json.Marshal(map[string]string{
		"public_key": reqPubKey,
		"otp":        corplinkTotpAt(opt.Code, serverTime),
	})
	resp, err := session.request(http.MethodPost, apiURL, strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("corplink vpn conn HTTP %d", resp.StatusCode)
	}

	var wg corplinkRespWgInfo
	if err := json.Unmarshal(raw, &wg); err != nil {
		return nil, fmt.Errorf("corplink api parse error: %v", err)
	}
	if wg.Code != 0 || wg.Data == nil {
		return nil, fmt.Errorf("corplink vpn conn code %d", wg.Code)
	}

	serverPubB64 := wg.Data.PublicKey
	serverPubHex := ""
	if b, err := base64.StdEncoding.DecodeString(serverPubB64); err == nil {
		serverPubHex = hex.EncodeToString(b)
	}
	info := &corplinkWgInfo{
		IP:              wg.Data.IP,
		IPMask:          wg.Data.IPMask,
		IPv6:            wg.Data.IPv6,
		ServerPubKey:    serverPubB64,
		ServerPubKeyHex: serverPubHex,
		MTU:             0,
		Server:          node.IP,
		Port:            node.VPNPort,
	}
	if wg.Data.Setting != nil {
		info.MTU = wg.Data.Setting.VPNMTU
		info.DNSAddresses, err = parseCorplinkDNSAddresses(
			wg.Data.Setting.VPNDNS, wg.Data.Setting.VPNDNSBackup,
		)
		if err != nil {
			return nil, err
		}
		info.DNSDomains, err = normalizeCorplinkDNSDomains(wg.Data.Setting.VPNDNSDomainSplit)
		if err != nil {
			return nil, err
		}
	}
	log.Infoln("[WG-Corplink] fetched wg_info: ip=%s", info.IP)
	return info, nil
}

// appendCorplinkCookie appends name=value to an existing Cookie header,
// skipping a name that is already present.
func appendCorplinkCookie(header, name, value string) string {
	if name == "" || value == "" {
		return header
	}
	for _, part := range strings.Split(header, ";") {
		if strings.TrimSpace(strings.SplitN(part, "=", 2)[0]) == name {
			return header
		}
	}
	if header == "" {
		return name + "=" + value
	}
	return header + "; " + name + "=" + value
}

// extractCorplinkCookie parses a single Set-Cookie header value and returns
// the value of the named cookie (empty if absent). It only inspects the first
// segment before ';' so attributes like Path=/ and Max-Age= are ignored.
func extractCorplinkCookie(setCookie, name string) string {
	first := strings.TrimSpace(strings.SplitN(setCookie, ";", 2)[0])
	kv := strings.SplitN(first, "=", 2)
	if len(kv) == 2 && kv[0] == name {
		return kv[1]
	}
	return ""
}

// corplinkTotp 基于 base32 密钥生成当前 30 秒槽的 6 位 TOTP。
func corplinkTotp(codeB32 string) (string, error) {
	return corplinkTotpAtChecked(codeB32, time.Now())
}

func corplinkTotpAt(codeB32 string, at time.Time) string {
	result, _ := corplinkTotpAtChecked(codeB32, at)
	return result
}

func corplinkTotpAtChecked(codeB32 string, at time.Time) (string, error) {
	if codeB32 == "" {
		return "", errors.New("corplink code not set")
	}
	padding := strings.Repeat("=", (8-len(codeB32)%8)%8)
	key, err := base32.StdEncoding.DecodeString(codeB32 + padding)
	if err != nil {
		return "", fmt.Errorf("corplink code decode: %v", err)
	}
	counter := uint64(at.Unix() / 30)
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, counter)
	mac := hmac.New(sha1.New, key)
	mac.Write(buf)
	sum := mac.Sum(nil)
	o := sum[len(sum)-1] & 0x0f
	val := binary.BigEndian.Uint32(sum[o:o+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", val%1000000), nil
}

// corplinkCookieExpiry 返回 cookie 文件中最早过期的 cookie 的剩余有效期。
// cookie 文件格式与 corplink 客户端一致（cookie-store 序列化的数组），
// 每个元素含 expires.AtUtc（RFC3339）。文件不存在/无过期信息时返回
// (极大值, false)，表示无法判断过期时间。
func corplinkCookieExpiry(path string) (time.Duration, bool) {
	if path == "" {
		return time.Hour * 24 * 365 * 10, false
	}
	f, err := os.Open(path)
	if err != nil {
		return time.Hour * 24 * 365 * 10, false
	}
	defer f.Close()

	var cookies []struct {
		Expires *struct {
			AtUtc string `json:"AtUtc"`
		} `json:"expires"`
	}
	if err := json.NewDecoder(f).Decode(&cookies); err != nil {
		return time.Hour * 24 * 365 * 10, false
	}
	now := time.Now()
	earliest := time.Hour * 24 * 365 * 10
	found := false
	for _, c := range cookies {
		if c.Expires == nil || c.Expires.AtUtc == "" {
			continue
		}
		exp, err := time.Parse(time.RFC3339, c.Expires.AtUtc)
		if err != nil {
			continue
		}
		left := exp.Sub(now)
		if left < earliest {
			earliest = left
		}
		found = true
	}
	return earliest, found
}

// isCookieExpired 判断 cookie 文件是否已过期（剩余有效期 <= 0）。
func isCookieExpired(path string) bool {
	left, found := corplinkCookieExpiry(path)
	if !found {
		return false
	}
	return left <= 0
}

// corplinkCookieWatchdog 启动一个后台协程，周期性检查 corplink cookie 的
// 剩余有效期，在即将过期时执行 RefreshCommand 刷新会话（对应 corplink-rs
// 的 --refresh-cookie 模式）。
//
// 触发策略：
//   - 剩余有效期 <= 1 小时：立即刷新（紧急，忽略时间窗口）。
//   - 剩余有效期 <= RefreshThresholdHours（默认 48 小时），且本地小时恰为
//     RefreshHour（默认 3，凌晨）：刷新。把常规刷新集中到低谷时段。
//
// 检查周期 1 小时。仅在 RefreshCommand 非空时启用。
func corplinkCookieWatchdog(opt CorplinkOption) {
	if opt.RefreshCommand == "" {
		return
	}
	threshold := time.Duration(opt.RefreshThresholdHours) * time.Hour
	if threshold <= 0 {
		threshold = 48 * time.Hour
	}
	refreshHour := opt.RefreshHour
	if refreshHour < 0 || refreshHour > 23 {
		refreshHour = 3
	}
	log.Infoln("[WG-Corplink] cookie watchdog enabled: threshold=%v refresh_hour=%d command=%s",
		threshold, refreshHour, opt.RefreshCommand)

	go func() {
		// 首次启动立即检查一次，随后每小时检查
		for {
			checkCorplinkCookieOnce(opt, threshold, refreshHour)
			time.Sleep(time.Hour)
		}
	}()
}

func checkCorplinkCookieOnce(opt CorplinkOption, threshold time.Duration, refreshHour int) {
	left, found := corplinkCookieExpiry(opt.CookieFile)
	if !found {
		return
	}
	nowHour := time.Now().Hour()
	immediate := left <= time.Hour
	withinThreshold := left <= threshold
	atRefreshHour := nowHour == refreshHour
	if !immediate && !(withinThreshold && atRefreshHour) {
		return
	}
	if immediate {
		log.Warnln("[WG-Corplink] cookie expires in %v (<1h), refreshing now", left)
	} else {
		log.Infoln("[WG-Corplink] cookie expires in %v (<=%v) at hour %d, refreshing",
			left, threshold, nowHour)
	}
	if err := runCorplinkRefresh(opt.RefreshCommand); err != nil {
		log.Warnln("[WG-Corplink] refresh command failed: %v", err)
		return
	}
	after, _ := corplinkCookieExpiry(opt.CookieFile)
	log.Infoln("[WG-Corplink] cookie refreshed, new expiry in %v", after)
}

// runCorplinkRefresh 执行刷新命令（带超时）。命令格式见 CorplinkOption.RefreshCommand。
func runCorplinkRefresh(cmd string) error {
	if cmd == "" {
		return errors.New("empty refresh command")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var c *exec.Cmd
	if runtime.GOOS == "windows" {
		c = exec.CommandContext(ctx, "cmd", "/C", cmd)
	} else {
		c = exec.CommandContext(ctx, "/bin/sh", "-c", cmd)
	}
	out, err := c.CombinedOutput()
	if err != nil {
		return fmt.Errorf("refresh command (%s) failed: %v: %s", cmd, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// loadCorplinkCookie 从 corplink 的 cookie 文件中读取 csrf-token 与 session。
func loadCorplinkCookie(path string) (csrf, cookieStr string, err error) {
	if path == "" {
		return "", "", nil
	}
	f, err := os.Open(path)
	if err != nil {
		return "", "", fmt.Errorf("corplink cookie file: %v", err)
	}
	defer f.Close()

	// corplink-rs writes cookie_store's native JSON representation on Android
	// (name/value/domain/path fields). Older clients wrote an array containing
	// raw_cookie instead. Decode both formats; the native JSON is syntactically
	// valid even when raw_cookie is absent, so it must not fall through to the
	// plain-text parser merely based on JSON decode success.
	var cookies []struct {
		RawCookie string `json:"raw_cookie"`
		Name      string `json:"name"`
		Value     string `json:"value"`
	}
	if err := json.NewDecoder(f).Decode(&cookies); err != nil {
		// Android bootstrap may not have Rust's CookieStore serializer. Accept
		// a plain Cookie header as a portable interchange format as well.
		if _, seekErr := f.Seek(0, io.SeekStart); seekErr != nil {
			return "", "", fmt.Errorf("corplink cookie parse: %v", err)
		}
		plain, readErr := io.ReadAll(f)
		if readErr != nil || strings.TrimSpace(string(plain)) == "" {
			return "", "", fmt.Errorf("corplink cookie parse: %v", err)
		}
		cookieStr = strings.TrimSpace(string(plain))
		for _, part := range strings.Split(cookieStr, ";") {
			seg := strings.TrimSpace(part)
			kv := strings.SplitN(seg, "=", 2)
			if len(kv) == 2 && kv[0] == "csrf-token" {
				csrf = kv[1]
			}
		}
		return csrf, cookieStr, nil
	}
	var parts []string
	for _, c := range cookies {
		raw := c.RawCookie
		if raw == "" && c.Name != "" {
			raw = c.Name + "=" + c.Value
		}
		seg := strings.SplitN(raw, ";", 2)[0]
		if strings.TrimSpace(seg) == "" {
			continue
		}
		parts = append(parts, seg)
		name := strings.SplitN(seg, "=", 2)[0]
		if name == "csrf-token" {
			csrf = strings.SplitN(seg, "=", 2)[1]
		}
	}
	return csrf, strings.Join(parts, "; "), nil
}

func parseCorplinkCookies(cookieHeader string) []*http.Cookie {
	var cookies []*http.Cookie
	for _, part := range strings.Split(cookieHeader, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 || kv[0] == "" {
			continue
		}
		cookies = append(cookies, &http.Cookie{Name: kv[0], Value: kv[1]})
	}
	return cookies
}
