// Package mtproxylctl bridges the panel to the MTProxyL bash CLI.
//
// telemt's REST API covers users and engine config, but MTProxyL owns
// host-level state with no API: mode, selfmask, firewall fixes, backups.
// Every command runs with MTPROXYL_ASSUME_YES=1 so confirmations resolve
// without a TTY.
package mtproxylctl

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

// ErrDisabled is returned when the MTProxyL bridge is not enabled in config.
var ErrDisabled = errors.New("mtproxyl integration is disabled")

// assumeYesEnv makes MTProxyL's prompts resolve without a terminal.
const assumeYesEnv = "MTPROXYL_ASSUME_YES=1"

// Client runs MTProxyL CLI commands.
type Client struct {
	cfg config.MtproxylConfig
}

func New(cfg config.MtproxylConfig) *Client {
	return &Client{cfg: cfg}
}

// Enabled reports whether the bridge is configured.
func (c *Client) Enabled() bool { return c.cfg.Enabled }

// BackupDir exposes the configured backup directory to handlers that need to
// resolve archive names against it.
func (c *Client) BackupDir() string { return c.cfg.BackupDir() }

// CommandError carries a failed command's output so handlers can surface the
// script's own message instead of a bare exit status.
type CommandError struct {
	Args   []string
	Err    error
	Output string
}

func (e *CommandError) Error() string {
	if e.Output != "" {
		return fmt.Sprintf("mtproxyl %s: %s: %s%s", strings.Join(e.Args, " "), e.Err, e.Output, sudoHint(e.Output))
	}
	return fmt.Sprintf("mtproxyl %s: %s", strings.Join(e.Args, " "), e.Err)
}

// sudoHint explains a sudo refusal. The drop-in in /etc/sudoers.d lists the
// subcommands one by one, so a panel updated in place keeps the rules it was
// installed with and a newly added command is denied until they are rewritten.
func sudoHint(output string) string {
	switch {
	case strings.Contains(output, "a password is required"),
		strings.Contains(output, "not allowed to execute"),
		strings.Contains(output, "may not run sudo"):
		return " — панели не хватает прав sudo на эту команду. " +
			"Обновите их: mtproxyl panel install"
	}
	return ""
}

func (e *CommandError) Unwrap() error { return e.Err }

// run executes `mtproxyl <args...>` and returns its stdout. stderr is captured
// separately: MTProxyL logs there, and mixing would corrupt --json output.
func (c *Client) run(ctx context.Context, args ...string) (string, error) {
	return c.runWithStdin(ctx, "", args...)
}

// runWithStdin is run() with data piped to standard input — for values too
// large or structured for an argument, like the hand-authored engine config.
func (c *Client) runWithStdin(ctx context.Context, stdin string, args ...string) (string, error) {
	if !c.cfg.Enabled {
		return "", ErrDisabled
	}

	ctx, cancel := context.WithTimeout(ctx, c.cfg.Timeout())
	defer cancel()

	name := c.cfg.ScriptPath
	full := args
	if c.cfg.UseSudo {
		name = "sudo"
		// -n: never prompt for a password. Without it a misconfigured sudoers
		// drop-in would block until the command times out.
		full = append([]string{"-n", c.cfg.ScriptPath}, args...)
	}

	cmd := exec.CommandContext(ctx, name, full...)
	// Inherit nothing: the panel's own environment is irrelevant to the script
	// and an inherited PATH/HOME from the service unit could change behavior.
	cmd.Env = []string{
		assumeYesEnv,
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
	}

	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	// A long operation can mirror its output somewhere the UI can read while it
	// is still running. The buffers stay authoritative for parsing; the sink is
	// only for display, so a slow reader cannot corrupt the result.
	if sink := progressFrom(ctx); sink != nil {
		cmd.Stdout = io.MultiWriter(&stdout, sink)
		cmd.Stderr = io.MultiWriter(&stderr, sink)
	}

	err := cmd.Run()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			err = fmt.Errorf("timed out after %s", c.cfg.Timeout())
		}
		return stdout.String(), &CommandError{
			Args:   args,
			Err:    err,
			Output: lastMeaningfulLine(stderr.String(), stdout.String()),
		}
	}
	return stdout.String(), nil
}

// lastMeaningfulLine picks the most informative line to show a user, preferring
// stderr (where MTProxyL logs errors) and falling back to stdout.
func lastMeaningfulLine(streams ...string) string {
	for _, s := range streams {
		lines := strings.Split(strings.TrimSpace(stripANSI(s)), "\n")
		for i := len(lines) - 1; i >= 0; i-- {
			if line := strings.TrimSpace(lines[i]); line != "" {
				return line
			}
		}
	}
	return ""
}

// stripANSI removes the color escapes MTProxyL emits, which would otherwise
// end up in API error messages and in the browser.
func stripANSI(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '[' {
			j := i + 2
			for j < len(s) && !((s[j] >= 'A' && s[j] <= 'Z') || (s[j] >= 'a' && s[j] <= 'z')) {
				j++
			}
			if j < len(s) {
				j++ // consume the final letter
			}
			i = j
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}
