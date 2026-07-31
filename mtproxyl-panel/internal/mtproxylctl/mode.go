package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Mode is MTProxyL's operating mode.
//
// In manager mode MTProxyL installs and owns its own telemt container. In
// reanimator mode it attaches to a telemt instance someone else installed and
// only applies host-level fixes to it.
type Mode string

const (
	ModeManager    Mode = "manager"
	ModeReanimator Mode = "reanimator"
)

// Valid reports whether m is a mode MTProxyL accepts.
func (m Mode) Valid() bool {
	return m == ModeManager || m == ModeReanimator
}

// ModeStatus is the output of `mtproxyl mode --json`.
type ModeStatus struct {
	Mode Mode `json:"mode"`
	// DetectedMode describes how a reanimator target is deployed
	// (docker/local/mtproxymax/config_only/...); "unknown" in manager mode.
	DetectedMode   string `json:"detected_mode"`
	DetectedConfig string `json:"detected_config"`
	Port           int    `json:"port"`
}

// GetMode returns the current mode and, in reanimator mode, what was detected.
func (c *Client) GetMode(ctx context.Context) (*ModeStatus, error) {
	out, err := c.run(ctx, "mode", "--json")
	if err != nil {
		return nil, err
	}
	var st ModeStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse mode output: %w", err)
	}
	return &st, nil
}

// SwitchMode switches MTProxyL between manager and reanimator.
//
// This is a destructive host-level operation: switching to reanimator offers to
// remove the panel's own container, and switching to manager may kick off a
// full install. It can therefore run for minutes.
func (c *Client) SwitchMode(ctx context.Context, m Mode) error {
	if !m.Valid() {
		return fmt.Errorf("unknown mode %q", m)
	}
	_, err := c.run(ctx, "mode", string(m))
	return err
}

// firstJSONLine extracts the first line that parses as a JSON document.
//
// Even with stderr split off, some MTProxyL code paths print a stray line to
// stdout before the payload, so we cannot assume the whole buffer is JSON.
// Validity is checked rather than just the opening brace, because MTProxyL's
// own log prefixes ("[i] ...", "[✓] ...") also start with a bracket.
func firstJSONLine(out string) string {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(stripANSI(line))
		if line == "" {
			continue
		}
		if (strings.HasPrefix(line, "{") || strings.HasPrefix(line, "[")) &&
			json.Valid([]byte(line)) {
			return line
		}
	}
	return strings.TrimSpace(out)
}
