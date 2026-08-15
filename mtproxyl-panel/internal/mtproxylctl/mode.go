package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Mode is MTProxyL's operating mode: manager owns its own telemt container,
// reanimator attaches to someone else's install and only applies host fixes.
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
	// ToolsOnly means the host runs somebody else's proxy (or none) and
	// MTProxyL is kept only for host-level fixes: zapret2, the SYN limiter,
	// By-MEKO tuning, geo blocking. There is no engine to ask about users,
	// links or traffic.
	ToolsOnly bool `json:"tools_only"`
	// DetectedMode describes how a reanimator target is deployed
	// (docker/local/mtproxymax/config_only/...); "unknown" in manager mode.
	DetectedMode   string `json:"detected_mode"`
	DetectedConfig string `json:"detected_config"`
	Port           int    `json:"port"`
	// SNI is the FakeTLS domain clients must present. In reanimator mode it
	// lives in the foreign target's config, not in MTProxyL's settings, so it
	// cannot be read from settings.conf.
	SNI string `json:"sni"`
	// EngineConfig is the config file that belongs to the *current* mode: the
	// foreign target's in reanimator, MTProxyL's own in manager.
	EngineConfig string `json:"engine_config"`
	// APIPort is where that engine exposes its REST API, APIEnabled whether it
	// is on. The panel holds one fixed telemt URL, so after a switch it can keep
	// polling the previous mode's engine.
	APIPort    int  `json:"api_port"`
	APIEnabled bool `json:"api_enabled"`
	// OwnContainer is the state of MTProxyL's own container ("running",
	// "exited", "absent", ...). Leaving for reanimator has to decide what to do
	// with it, and there is nothing to ask about when it is "absent".
	OwnContainer string `json:"own_container"`
	// Running reports whether the engine of the current mode is up, so the UI
	// can offer start or stop rather than both.
	Running bool `json:"running"`
	// LogKind and LogTarget say where the current mode's engine logs live:
	// "docker" with a container or "service" with a unit, empty when unknown.
	// The panel is configured with one container at install time.
	LogKind   string `json:"log_kind"`
	LogTarget string `json:"log_target"`
}

// ContainerDisposition says what to do with MTProxyL's own container when
// leaving manager mode. Passed explicitly: the panel cannot answer the CLI's
// prompt, and the default would delete the container silently.
type ContainerDisposition string

const (
	// ContainerRemove stops and deletes the container (the CLI's default).
	ContainerRemove ContainerDisposition = "remove"
	// ContainerStop stops it but keeps it, so switching back is quick.
	ContainerStop ContainerDisposition = "stop"
	// ContainerKeep leaves it running; it will keep holding the port.
	ContainerKeep ContainerDisposition = "keep"
)

func (d ContainerDisposition) Valid() bool {
	return d == ContainerRemove || d == ContainerStop || d == ContainerKeep
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

// SwitchMode switches MTProxyL between manager and reanimator. Destructive and
// slow: it may dispose of the container or kick off a full install.
// disposition applies only when switching to reanimator and must be set there.
func (c *Client) SwitchMode(ctx context.Context, m Mode, disposition ContainerDisposition) error {
	if !m.Valid() {
		return fmt.Errorf("unknown mode %q", m)
	}
	if m == ModeReanimator {
		if !disposition.Valid() {
			return fmt.Errorf("switching to reanimator needs a container disposition")
		}
		_, err := c.run(ctx, "mode", string(m), string(disposition))
		return err
	}
	_, err := c.run(ctx, "mode", string(m))
	return err
}

// TargetConfigShow returns the reanimator target's config verbatim: the panel
// cannot open it (telemt:telemt, 750), so MTProxyL reads it as root.
// Unchanged output — stripping ANSI would corrupt such a config.
func (c *Client) TargetConfigShow(ctx context.Context) (string, error) {
	return c.run(ctx, "target-config", "show")
}

// TargetConfigWrite replaces the reanimator target's config file. Content goes
// over stdin: multi-line TOML with quotes is awkward and risky as an argument.
// MTProxyL backs up the old file and keeps its owner and mode.
func (c *Client) TargetConfigWrite(ctx context.Context, content string, restart bool) (string, error) {
	if strings.TrimSpace(content) == "" {
		return "", fmt.Errorf("config must not be empty")
	}
	args := []string{"target-config", "write"}
	if restart {
		args = append(args, "--restart")
	}
	out, err := c.runWithStdin(ctx, content, args...)
	return stripANSI(out), err
}

// ProxyAction controls the engine of whichever mode is active: MTProxyL's own
// container in manager mode, the detected target in reanimator mode.
type ProxyAction string

const (
	ProxyStart   ProxyAction = "start"
	ProxyStop    ProxyAction = "stop"
	ProxyRestart ProxyAction = "restart"
)

func (a ProxyAction) Valid() bool {
	return a == ProxyStart || a == ProxyStop || a == ProxyRestart
}

// ControlProxy starts, stops or restarts the engine.
func (c *Client) ControlProxy(ctx context.Context, a ProxyAction) (string, error) {
	if !a.Valid() {
		return "", fmt.Errorf("unknown proxy action %q", a)
	}
	out, err := c.run(ctx, string(a))
	return stripANSI(out), err
}

// firstJSONLine extracts the first line that parses as a JSON document.
// Some MTProxyL paths print a stray line to stdout first. Validity is checked
// rather than the opening brace: its log prefixes also start with one.
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
