package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Calls used by mtproxyl-api, the external control API. They go through the
// same CLI as the panel, so both see one source of truth.

// rfc3339Re accepts what the CLI normalises: a bare date or a full RFC3339
// timestamp. "0" means no expiry.
var rfc3339Re = regexp.MustCompile(`^(0|\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2}))?)$`)

// SetLimitsFull writes all four caps at once. The CLI treats an empty
// argument as zero, so a partial update must send every value.
func (c *Client) SetLimitsFull(ctx context.Context, label string, conns, ips, quota int64, expires string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	if conns < 0 || ips < 0 || quota < 0 {
		return "", fmt.Errorf("лимиты не могут быть отрицательными")
	}
	if expires == "" {
		expires = "0"
	}
	if !rfc3339Re.MatchString(expires) {
		return "", fmt.Errorf("срок: RFC3339, ГГГГ-ММ-ДД или пусто")
	}
	out, err := c.run(ctx, "secret", "setlimits", label,
		strconv.FormatInt(conns, 10), strconv.FormatInt(ips, 10), strconv.FormatInt(quota, 10), expires)
	return stripANSI(out), err
}

// ResetQuota zeroes the quota the engine has counted for a user.
func (c *Client) ResetQuota(ctx context.Context, label string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "secret", "reset-quota", label)
	return stripANSI(out), err
}

// ResetUserTraffic clears MTProxyL's accumulated traffic and IP history for
// one user. The engine's quota counter is separate — see ResetQuota.
func (c *Client) ResetUserTraffic(ctx context.Context, label string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "stats", "reset", "user", label)
	return stripANSI(out), err
}

// Links returns every working link of a user: tg:// for each enabled kind and
// the WEB link when WEB Proxy is on.
func (c *Client) Links(ctx context.Context, label string) ([]string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return nil, err
	}
	out, err := c.run(ctx, "secret", "link", label)
	if err != nil {
		return nil, err
	}
	links := []string{}
	for _, line := range strings.Split(stripANSI(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "tg://") || strings.HasPrefix(line, "https://t.me/") {
			links = append(links, line)
		}
	}
	return links, nil
}

// EngineUser — строка ответа движка на /v1/users: живые подключения и IP.
type EngineUser struct {
	Username            string   `json:"username"`
	InRuntime           bool     `json:"in_runtime"`
	CurrentConnections  int64    `json:"current_connections"`
	ActiveUniqueIPs     int      `json:"active_unique_ips"`
	ActiveUniqueIPsList []string `json:"active_unique_ips_list"`
	RecentUniqueIPs     int      `json:"recent_unique_ips"`
	RecentUniqueIPsList []string `json:"recent_unique_ips_list"`
	TotalOctets         int64    `json:"total_octets"`
}

// APIView — `mtproxyl secret api-view [метка]`: ссылки по меткам и живые
// данные движка. Live пуст, если API движка не ответил.
type APIView struct {
	Links map[string][]string
	Live  map[string]EngineUser
	// Users — то же, что ListSecrets; nil, если скрипт старше 1.7.3.
	Users []Secret
}

func (c *Client) APIView(ctx context.Context, label string) (*APIView, error) {
	args := []string{"secret", "api-view"}
	if label != "" {
		if err := ValidateSecretLabel(label); err != nil {
			return nil, err
		}
		args = append(args, label)
	}
	out, err := c.run(ctx, args...)
	if err != nil {
		return nil, err
	}
	var raw struct {
		Links map[string][]string `json:"links"`
		Live  *struct {
			Data []EngineUser `json:"data"`
		} `json:"live"`
		Users []Secret `json:"users"`
	}
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &raw); err != nil {
		return nil, fmt.Errorf("api-view: неожиданный ответ")
	}
	v := &APIView{Links: raw.Links, Live: map[string]EngineUser{}, Users: raw.Users}
	if v.Links == nil {
		v.Links = map[string][]string{}
	}
	if raw.Live != nil {
		for _, u := range raw.Live.Data {
			v.Live[u.Username] = u
		}
	}
	return v, nil
}

// RotateSecretTo ставит пользователю заданный секрет (32 hex).
func (c *Client) RotateSecretTo(ctx context.Context, label, secret string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	if !secretHexRe.MatchString(secret) {
		return "", fmt.Errorf("секрет: ровно 32 шестнадцатеричных символа")
	}
	out, err := c.run(ctx, "secret", "rotate", label, strings.ToLower(secret))
	return stripANSI(out), err
}

// StatusRaw returns `mtproxyl status --json` untouched.
func (c *Client) StatusRaw(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "status", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("status: неожиданный ответ")
	}
	return json.RawMessage(line), nil
}

// RestartProxy restarts the engine (manager) or the target (reanimator).
func (c *Client) RestartProxy(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "restart")
	return stripANSI(out), err
}
