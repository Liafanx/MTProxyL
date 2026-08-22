package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// ErrStatsUnsupported means the installed MTProxyL predates `stats`.
var ErrStatsUnsupported = errors.New(
	"установленный MTProxyL не умеет сбрасывать статистику — обновите его: mtproxyl update")

// StatsTraffic counts what the traffic database holds.
type StatsTraffic struct {
	Users    int   `json:"users"`
	Orphans  int   `json:"orphans"`
	InBytes  int64 `json:"in_bytes"`
	OutBytes int64 `json:"out_bytes"`
}

// StatsIPs counts what the address history holds.
type StatsIPs struct {
	Records int `json:"records"`
	Orphans int `json:"orphans"`
}

// StatsOverview is `mtproxyl stats --json`.
type StatsOverview struct {
	Mode    string       `json:"mode"`
	Traffic StatsTraffic `json:"traffic"`
	IPs     StatsIPs     `json:"ips"`
}

// statsScopes are the only reset targets the panel may ask for.
var statsScopes = map[string]bool{
	"all": true, "traffic": true, "ips": true, "orphans": true, "user": true,
}

// Stats reports what has accumulated.
func (c *Client) Stats(ctx context.Context) (*StatsOverview, error) {
	out, err := c.run(ctx, "stats", "--json")
	if err != nil {
		var ce *CommandError
		if errors.As(err, &ce) && strings.Contains(ce.Output, "Неизвестная команда") {
			return nil, ErrStatsUnsupported
		}
		return nil, err
	}
	var s StatsOverview
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &s); err != nil {
		return nil, ErrStatsUnsupported
	}
	return &s, nil
}

// StatsReset clears accumulated counters. Settings and users stay untouched.
func (c *Client) StatsReset(ctx context.Context, scope, label string) (string, error) {
	if !statsScopes[scope] {
		return "", fmt.Errorf("недопустимая область сброса: %s", scope)
	}
	if scope == "user" {
		l := strings.TrimSpace(label)
		if err := ValidateSecretLabel(l); err != nil {
			return "", err
		}
		out, err := c.run(ctx, "stats", "reset", "user", l)
		return stripANSI(out), err
	}
	out, err := c.run(ctx, "stats", "reset", scope)
	return stripANSI(out), err
}
