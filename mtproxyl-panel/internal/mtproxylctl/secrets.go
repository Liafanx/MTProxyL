package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
)

// Secret is one entry of `mtproxyl secret list --json`.
//
// MTProxyL calls these "secrets" and telemt calls them "users"; they are the
// same thing seen from two sides. The panel speaks of users, so the HTTP layer
// renames the fields — this struct stays close to the CLI.
type Secret struct {
	Label      string `json:"label"`
	Secret     string `json:"secret"`
	Created    int64  `json:"created"`
	Enabled    bool   `json:"enabled"`
	MaxConns   int    `json:"max_conns"`
	MaxIPs     int    `json:"max_ips"`
	QuotaBytes int64  `json:"quota_bytes"`
	// Expires is "0" for no expiry, otherwise an RFC3339 timestamp.
	Expires string `json:"expires"`
	Notes   string `json:"notes"`
}

// secretLabelRe mirrors MTProxyL's own rule for labels, with one tightening:
// the first character must be alphanumeric. MTProxyL would happily accept a
// label of "--help", which is a confusing thing to have in a config and an
// argument that reads as a flag everywhere it is later echoed.
var secretLabelRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$`)

// secretHexRe is telemt's secret format: exactly 32 hex characters.
var secretHexRe = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)

// ValidateSecretLabel checks a user label before it reaches the CLI.
func ValidateSecretLabel(label string) error {
	if !secretLabelRe.MatchString(label) {
		return fmt.Errorf("метка: латиница, цифры, дефис и подчёркивание, до 32 символов")
	}
	return nil
}

// ListSecrets returns the users MTProxyL owns.
//
// In manager mode this is the authoritative list: telemt's config is mounted
// read-only into its container, so the engine cannot write users at all and
// its own POST /v1/users fails with "Device or resource busy".
func (c *Client) ListSecrets(ctx context.Context) ([]Secret, error) {
	out, err := c.run(ctx, "secret", "list", "--json")
	if err != nil {
		return nil, err
	}
	var list []Secret
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse secret list: %w", err)
	}
	if list == nil {
		list = []Secret{}
	}
	return list, nil
}

// AddSecret creates a user. An empty secret makes MTProxyL generate one.
func (c *Client) AddSecret(ctx context.Context, label, secret string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	args := []string{"secret", "add", label}
	if secret != "" {
		if !secretHexRe.MatchString(secret) {
			return "", fmt.Errorf("секрет: ровно 32 шестнадцатеричных символа")
		}
		args = append(args, secret)
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

// RemoveSecret deletes a user.
func (c *Client) RemoveSecret(ctx context.Context, label string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "secret", "remove", label)
	return stripANSI(out), err
}

// RotateSecret issues a new key for a user, invalidating their old links.
func (c *Client) RotateSecret(ctx context.Context, label string) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "secret", "rotate", label)
	return stripANSI(out), err
}

// ToggleSecret enables or disables a user without deleting them.
func (c *Client) ToggleSecret(ctx context.Context, label string, enable bool) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	action := "disable"
	if enable {
		action = "enable"
	}
	out, err := c.run(ctx, "secret", action, label)
	return stripANSI(out), err
}

// RenameSecret changes a user's label.
func (c *Client) RenameSecret(ctx context.Context, from, to string) (string, error) {
	if err := ValidateSecretLabel(from); err != nil {
		return "", err
	}
	if err := ValidateSecretLabel(to); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "secret", "rename", from, to)
	return stripANSI(out), err
}

// SecretLimits are the per-user caps MTProxyL stores.
//
// Every field is optional on the wire; a nil pointer means "leave as is",
// which matches `secret setlimits` treating an empty argument as unchanged.
type SecretLimits struct {
	MaxConns   *int   `json:"max_conns"`
	MaxIPs     *int   `json:"max_ips"`
	QuotaBytes *int64 `json:"quota_bytes"`
	// Expires is "" (unchanged), "0"/"never", or YYYY-MM-DD.
	Expires *string `json:"expires"`
}

var expiresRe = regexp.MustCompile(`^(0|never|\d{4}-\d{2}-\d{2})$`)

// SetSecretLimits applies connection, IP, quota and expiry caps.
func (c *Client) SetSecretLimits(ctx context.Context, label string, l SecretLimits) (string, error) {
	if err := ValidateSecretLabel(label); err != nil {
		return "", err
	}
	// Positional and order-sensitive, matching the CLI:
	//   secret setlimits <label> <conns> <ips> <quota> [expires]
	// An empty argument means "leave this one alone" on both sides.
	conns, ips, quota, expires := "", "", "", ""
	if l.MaxConns != nil {
		if *l.MaxConns < 0 {
			return "", fmt.Errorf("лимит соединений не может быть отрицательным")
		}
		conns = strconv.Itoa(*l.MaxConns)
	}
	if l.MaxIPs != nil {
		if *l.MaxIPs < 0 {
			return "", fmt.Errorf("лимит IP не может быть отрицательным")
		}
		ips = strconv.Itoa(*l.MaxIPs)
	}
	if l.QuotaBytes != nil {
		if *l.QuotaBytes < 0 {
			return "", fmt.Errorf("квота не может быть отрицательной")
		}
		quota = strconv.FormatInt(*l.QuotaBytes, 10)
	}
	if l.Expires != nil {
		if !expiresRe.MatchString(*l.Expires) {
			return "", fmt.Errorf("срок: 0, never или ГГГГ-ММ-ДД")
		}
		expires = *l.Expires
	}

	out, err := c.run(ctx, "secret", "setlimits", label, conns, ips, quota, expires)
	return stripANSI(out), err
}
