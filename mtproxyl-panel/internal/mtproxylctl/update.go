package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
)

// ErrUpdateUnsupported means the installed MTProxyL predates the panel's
// update controls: `update --check` is not a command it knows.
var ErrUpdateUnsupported = errors.New(
	"установленный MTProxyL не умеет обновляться из панели — обновите его один раз " +
		"из терминала: mtproxyl update")

// UpdateInfo is the output of `mtproxyl update --check`.
type UpdateInfo struct {
	Current         string `json:"current"`
	Latest          string `json:"latest"`
	UpdateAvailable bool   `json:"update_available"`
	// Branch is where updates come from: main for a release install, the
	// branch name when MTProxyL was installed from one.
	Branch     string `json:"branch,omitempty"`
	ReleaseURL string `json:"release_url,omitempty"`
	// Error carries a failed lookup — github unreachable, mostly. Not a
	// command failure: the installed version is still known and worth showing.
	Error string `json:"error,omitempty"`
	// CheckedAt is filled in by the panel, not the CLI.
	CheckedAt string `json:"checked_at,omitempty"`
}

// CheckUpdate asks MTProxyL whether a newer version is published.
// The subcommand is deliberately not `update --check`: versions before 1.4.7
// ignore unknown flags and would run a real update instead of reporting one.
func (c *Client) CheckUpdate(ctx context.Context) (*UpdateInfo, error) {
	out, err := c.run(ctx, "update-check")
	if err != nil {
		var ce *CommandError
		if errors.As(err, &ce) && strings.Contains(ce.Output, "Неизвестная команда") {
			return nil, ErrUpdateUnsupported
		}
		return nil, err
	}
	var info UpdateInfo
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &info); err != nil {
		// Не JSON — значит, скрипт этой команды не знает и напечатал свою
		// справку. Панель новее самого MTProxyL: сказать это прямо полезнее,
		// чем показать, на каком байте сломался разбор.
		return nil, ErrUpdateUnsupported
	}
	return &info, nil
}

// ApplyUpdate downloads and installs the published version of MTProxyL.
// --no-restart is not optional: without it the script ends by exec'ing its
// interactive menu, which would hang until the command times out — and a
// script old enough to ignore the flag would do exactly that, so the caller
// must confirm support with CheckUpdate first.
func (c *Client) ApplyUpdate(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "update", "--no-restart")
	return stripANSI(out), err
}
