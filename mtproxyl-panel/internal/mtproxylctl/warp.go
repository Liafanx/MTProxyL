package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

// WarpExit is where Cloudflare says we come out; Confirmed is false when the
// tunnel did not answer.
type WarpExit struct {
	IP        string `json:"ip"`
	Loc       string `json:"loc"`
	Colo      string `json:"colo"`
	Confirmed bool   `json:"confirmed"`
}

// WarpStatus is `mtproxyl warp status --json`.
type WarpStatus struct {
	WatchdogEnabled bool       `json:"watchdog_enabled"`
	ActiveEndpoint  string     `json:"active_endpoint"`
	ActiveProto     string     `json:"active_proto"`
	Health          WarpHealth `json:"health"`
	Enabled         bool       `json:"enabled"`
	// Mode: socks (A), iface (B) или upstream (C).
	Mode      string `json:"mode"`
	Proto     string `json:"proto"`
	Endpoint  string `json:"endpoint"`
	Location  string `json:"location"`
	Installed bool   `json:"installed"`
	Version   string `json:"version"`
	// socks — в режимах socks и upstream, redirect — только в socks.
	SocksActive    bool `json:"socks_active"`
	RedirectActive bool `json:"redirect_active"`
	IfaceActive    bool `json:"iface_active"`
	NftApplied     bool `json:"nft_applied"`
	CidrCount      int  `json:"cidr_count"`
	SocksPort      int  `json:"socks_port"`
	RedirectPort   int  `json:"redirect_port"`
	// MatchedPackets is the nft counter: proof the route is actually used.
	MatchedPackets int64    `json:"matched_packets"`
	Exit           WarpExit `json:"exit"`
}

type WarpHealth struct {
	CheckedAt      int64  `json:"checked_at"`
	Failures       int    `json:"failures"`
	LastRecoveryAt int64  `json:"last_recovery_at"`
	Result         string `json:"result"`
	Error          string `json:"error"`
}

type WarpPreflight struct {
	Mode                       string   `json:"mode"`
	MiddleProxyEnabled         bool     `json:"middle_proxy_enabled"`
	CanDisableMiddleProxy      bool     `json:"can_disable_middle_proxy"`
	OwnsEngineConfig           bool     `json:"owns_engine_config"`
	ManualEngineConfig         bool     `json:"manual_engine_config"`
	DefaultUpstreams           []string `json:"default_upstreams"`
	CanDisableDefaultUpstreams bool     `json:"can_disable_default_upstreams"`
}

// ErrWarpUnsupported means the installed MTProxyL predates the WARP route.
var ErrWarpUnsupported = errWarpUnsupported()

func errWarpUnsupported() error {
	return fmt.Errorf("установленный MTProxyL не умеет маршрут до Telegram через WARP")
}

// WarpGetStatus returns the current state of the route.
func (c *Client) WarpGetStatus(ctx context.Context) (*WarpStatus, error) {
	out, err := c.run(ctx, "warp", "status", "--json")
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrWarpUnsupported
		}
		return nil, err
	}
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrWarpUnsupported
	}
	var st WarpStatus
	if err := json.Unmarshal([]byte(line), &st); err != nil {
		return nil, fmt.Errorf("parse warp status: %w", err)
	}
	return &st, nil
}

func validateWarpMode(mode string) error {
	switch mode {
	case "socks", "iface", "upstream":
		return nil
	default:
		return fmt.Errorf("вариант: socks (A), iface (B) или upstream (C)")
	}
}

func (c *Client) WarpPreflight(ctx context.Context, mode string) (*WarpPreflight, error) {
	if err := validateWarpMode(mode); err != nil {
		return nil, err
	}
	out, err := c.run(ctx, "warp", "preflight", mode, "--json")
	if err != nil {
		return nil, err
	}
	var result WarpPreflight
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &result); err != nil {
		return nil, fmt.Errorf("не удалось прочитать проверку WARP: обновите MTProxyL")
	}
	if result.DefaultUpstreams == nil {
		result.DefaultUpstreams = []string{}
	}
	return &result, nil
}

// WarpEnable turns the route on after explicit consent to conflicting changes.
func (c *Client) WarpEnable(ctx context.Context, mode string, allowDisableME, allowDisableDefaultUpstreams bool) (string, error) {
	if err := validateWarpMode(mode); err != nil {
		return "", err
	}
	args := []string{"warp", "on", mode}
	if allowDisableME {
		args = append(args, "--allow-disable-me")
	}
	if allowDisableDefaultUpstreams {
		args = append(args, "--allow-disable-default-upstreams")
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

// WarpDisable removes the rules and stops the services.
func (c *Client) WarpDisable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "warp", "off")
	return stripANSI(out), err
}

// WarpScan looks for the best endpoint without changing anything.
func (c *Client) WarpScan(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "warp", "scan")
	return stripANSI(out), err
}

func (c *Client) WarpScanMode(ctx context.Context, mode string, deep bool) (string, error) {
	args := []string{"warp", "scan"}
	if mode != "" {
		if err := validateWarpMode(mode); err != nil {
			return "", err
		}
		args = append(args, mode)
	}
	if deep {
		args = append(args, "--deep")
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

func (c *Client) WarpAction(ctx context.Context, action string) (string, error) {
	var args []string
	switch action {
	case "apply", "recover", "install":
		args = []string{"warp", action}
	case "watchdog-on":
		args = []string{"warp", "watchdog", "on"}
	case "watchdog-off":
		args = []string{"warp", "watchdog", "off"}
	default:
		return "", fmt.Errorf("неверное действие WARP")
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

// WarpScanNode is one working endpoint from the last scan.
type WarpScanNode struct {
	TunnelPing string `json:"tunnel_ping"`
	Loss       string `json:"loss"`
	Node       string `json:"node"`
	Endpoint   string `json:"endpoint"`
	Ping       string `json:"ping"`
	Region     string `json:"region"`
	Location   string `json:"location"`
}

// WarpScanResult is `mtproxyl warp scan --json`: the cached scan, not a new one.
type WarpScanResult struct {
	Status       string         `json:"status"`
	Error        string         `json:"error"`
	BestEndpoint string         `json:"best_endpoint"`
	ScannedAt    int64          `json:"scanned_at"`
	Proto        string         `json:"proto"`
	Filter       string         `json:"filter"`
	Depth        string         `json:"depth"`
	Nodes        []WarpScanNode `json:"nodes"`
}

// WarpGetScan returns the last scan without starting a new one.
func (c *Client) WarpGetScan(ctx context.Context) (*WarpScanResult, error) {
	out, err := c.run(ctx, "warp", "scan", "--json")
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrWarpUnsupported
		}
		return nil, err
	}
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrWarpUnsupported
	}
	var res WarpScanResult
	if err := json.Unmarshal([]byte(line), &res); err != nil {
		return nil, fmt.Errorf("parse warp scan: %w", err)
	}
	return &res, nil
}

// WarpReapply refreshes the Telegram subnet list and the rules built from it.
func (c *Client) WarpReapply(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "warp", "reapply")
	return stripANSI(out), err
}

// Country codes (DE) and Cloudflare node codes (FRA), comma-separated.
var warpLocationRe = regexp.MustCompile(`^[A-Za-z]{2,3}(,[A-Za-z]{2,3})*$`)

// WarpSetLocation pins where to come out; an empty value restores automatic.
func (c *Client) WarpSetLocation(ctx context.Context, loc string) (string, error) {
	arg := strings.TrimSpace(loc)
	if arg == "" {
		arg = "clear"
	} else if !warpLocationRe.MatchString(arg) {
		return "", fmt.Errorf("локация: коды стран (DE,NL) или узлов Cloudflare (FRA,AMS)")
	}
	out, err := c.run(ctx, "warp", "location", arg)
	return stripANSI(out), err
}

func validWarpEndpoint(ep string) bool {
	ap, err := netip.ParseAddrPort(ep)
	return err == nil && ap.Port() != 0 && ap.Addr().Zone() == ""
}

// WarpSetEndpoint pins the tunnel endpoint; empty goes back to scanning.
func (c *Client) WarpSetEndpoint(ctx context.Context, ep string) (string, error) {
	arg := strings.TrimSpace(ep)
	if arg == "" {
		arg = "clear"
	} else if !validWarpEndpoint(arg) {
		return "", fmt.Errorf("эндпоинт: адрес вида 188.114.98.58:2408")
	}
	out, err := c.run(ctx, "warp", "endpoint", arg)
	return stripANSI(out), err
}

func (c *Client) WarpSetSettings(ctx context.Context, proto, location, endpoint *string) (string, error) {
	p, l, e := "keep", "keep", "keep"
	if proto != nil {
		p = *proto
		switch p {
		case "awg", "wg", "masque", "masque-h2":
		default:
			return "", fmt.Errorf("неверный протокол WARP")
		}
	}
	if location != nil {
		l = strings.ToUpper(strings.TrimSpace(*location))
		if l == "" {
			l = "clear"
		} else if !warpLocationRe.MatchString(l) {
			return "", fmt.Errorf("неверная локация WARP")
		}
	}
	if endpoint != nil {
		e = strings.TrimSpace(*endpoint)
		if e == "" {
			e = "clear"
		} else if !validWarpEndpoint(e) {
			return "", fmt.Errorf("неверный endpoint WARP")
		}
	}
	out, err := c.run(ctx, "warp", "settings", p, l, e)
	return stripANSI(out), err
}

// WarpSetProto picks the protocol; only mode socks honours it.
func (c *Client) WarpSetProto(ctx context.Context, proto string) (string, error) {
	switch proto {
	case "awg", "wg", "masque", "masque-h2":
	default:
		return "", fmt.Errorf("протокол: awg, wg, masque или masque-h2")
	}
	out, err := c.run(ctx, "warp", "proto", proto)
	return stripANSI(out), err
}
