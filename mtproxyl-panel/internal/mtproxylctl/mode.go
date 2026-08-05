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
	// EngineConfig is the config file that belongs to the *current* mode: the
	// foreign target's in reanimator, MTProxyL's own in manager.
	EngineConfig string `json:"engine_config"`
	// APIPort is where that engine exposes its REST API, and APIEnabled whether
	// it is turned on there at all.
	//
	// The panel is pointed at one fixed telemt URL when it is installed. Nothing
	// updates it on a mode switch, so it can keep polling the previous mode's
	// engine and present another instance's users and traffic as the current
	// one's. Reporting the mode's real endpoint lets the UI catch that.
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
	// "docker" with a container name, or "service" with a systemd unit. Empty
	// when MTProxyL cannot tell.
	//
	// The panel is configured with one container name at install time. After a
	// switch to reanimator that container is gone, and reading logs from it
	// failed with a permission error that looked like a Docker problem rather
	// than what it was: the wrong container.
	LogKind   string `json:"log_kind"`
	LogTarget string `json:"log_target"`
}

// ContainerDisposition says what to do with MTProxyL's own container when
// leaving manager mode.
//
// The CLI asks this interactively. The panel cannot answer an interactive
// prompt, and MTPROXYL_ASSUME_YES would silently pick the default — deleting
// the container without asking — so the choice is passed explicitly.
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

// SwitchMode switches MTProxyL between manager and reanimator.
//
// This is a destructive host-level operation: switching to reanimator disposes
// of the panel's own container, and switching to manager may kick off a full
// install. It can therefore run for minutes.
//
// disposition applies only when switching to reanimator and must be set there:
// without it the CLI would fall back to its own default and delete the
// container, which is the one outcome the user has to choose deliberately.
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

// TargetConfigShow returns the reanimator target's config file verbatim.
//
// The panel runs unprivileged and the target's config belongs to the target —
// for a systemd install that is telemt:telemt in a 750 directory, which the
// panel cannot even open. MTProxyL reads it as root, the same way superexpert
// show serves the manager's own config.
//
// The output is returned unchanged: stripping ANSI here would corrupt a config
// that legitimately contains such sequences.
func (c *Client) TargetConfigShow(ctx context.Context) (string, error) {
	return c.run(ctx, "target-config", "show")
}

// TargetConfigWrite replaces the reanimator target's config file.
//
// The content goes over stdin rather than as an argument: it is multi-line TOML
// with quotes, which would be both awkward and risky to pass on a command line.
// MTProxyL backs the old file up and keeps its owner and mode, so the target can
// still read what it is given.
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
