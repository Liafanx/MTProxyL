package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// The WARP route lives in MTProxyL: the rules are kernel rules, and they have
// to survive the panel being closed. Everything here only asks the script.

// WarpExit is where Cloudflare says we come out. Confirmed is false when the
// tunnel did not answer — the panel shows that as «не подтверждён», because a
// running service is not the same as a working route.
type WarpExit struct {
	IP        string `json:"ip"`
	Loc       string `json:"loc"`
	Colo      string `json:"colo"`
	Confirmed bool   `json:"confirmed"`
}

// WarpStatus is `mtproxyl warp status --json`.
type WarpStatus struct {
	Enabled bool `json:"enabled"`
	// Mode is "socks" (вариант A) or "iface" (вариант B).
	Mode      string `json:"mode"`
	Proto     string `json:"proto"`
	Endpoint  string `json:"endpoint"`
	Location  string `json:"location"`
	Installed bool   `json:"installed"`
	Version   string `json:"version"`
	// SocksActive and RedirectActive matter in mode socks, IfaceActive in mode
	// iface; the script always reports all three.
	SocksActive    bool `json:"socks_active"`
	RedirectActive bool `json:"redirect_active"`
	IfaceActive    bool `json:"iface_active"`
	NftApplied     bool `json:"nft_applied"`
	CidrCount      int  `json:"cidr_count"`
	SocksPort      int  `json:"socks_port"`
	RedirectPort   int  `json:"redirect_port"`
	// MatchedPackets is what the nft counter saw: the only evidence that
	// Telegram traffic really goes into the tunnel.
	MatchedPackets int64    `json:"matched_packets"`
	Exit           WarpExit `json:"exit"`
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

// WarpEnable turns the route on. Both modes scan for a live endpoint first, so
// this runs for minutes — the caller is expected to be the operation runner.
func (c *Client) WarpEnable(ctx context.Context, mode string) (string, error) {
	if mode != "socks" && mode != "iface" {
		return "", fmt.Errorf("вариант: socks (A) или iface (B)")
	}
	out, err := c.run(ctx, "warp", "on", mode)
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

// WarpReapply refreshes the Telegram subnet list and the rules built from it.
func (c *Client) WarpReapply(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "warp", "reapply")
	return stripANSI(out), err
}

// warpLocationRe is a comma-separated list of country codes (DE) and Cloudflare
// node codes (FRA). Empty means «best by latency».
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

var warpEndpointRe = regexp.MustCompile(`^[0-9a-fA-F:.]+:[0-9]{1,5}$`)

// WarpSetEndpoint pins the tunnel endpoint; empty goes back to scanning.
func (c *Client) WarpSetEndpoint(ctx context.Context, ep string) (string, error) {
	arg := strings.TrimSpace(ep)
	if arg == "" {
		arg = "clear"
	} else if !warpEndpointRe.MatchString(arg) {
		return "", fmt.Errorf("эндпоинт: адрес вида 188.114.98.58:2408")
	}
	out, err := c.run(ctx, "warp", "endpoint", arg)
	return stripANSI(out), err
}

// WarpSetProto picks the tunnel protocol. Only mode socks honours it: the
// kernel interface speaks plain WireGuard and nothing else.
func (c *Client) WarpSetProto(ctx context.Context, proto string) (string, error) {
	switch proto {
	case "awg", "wg", "masque", "masque-h2":
	default:
		return "", fmt.Errorf("протокол: awg, wg, masque или masque-h2")
	}
	out, err := c.run(ctx, "warp", "proto", proto)
	return stripANSI(out), err
}
