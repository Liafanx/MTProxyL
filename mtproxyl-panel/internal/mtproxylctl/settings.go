package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
)

// Setting is one entry of `mtproxyl settings list --json` — MTProxyL's own
// settings from settings.conf, not the engine's config. In manager mode that
// config is mounted read-only, so MTProxyL regenerates it from these values.
type Setting struct {
	Key         string `json:"key"`
	Validator   string `json:"validator"`
	Description string `json:"description"`
	Value       string `json:"value"`
}

// settingKeyRe matches the SHOUTY_SNAKE names MTProxyL uses for settings.
var settingKeyRe = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)

// settingValueRe covers ports, domains, hex tags, booleans and enum words.
// Brackets, quotes and whitespace stay out; empty is allowed — that is how an
// ad tag or a pinned IP is cleared.
var settingValueRe = regexp.MustCompile(`^[A-Za-z0-9_.:@%+-]*$`)

// ValidateSetting checks a key/value pair before it reaches the CLI. MTProxyL
// validates again against its own catalog; this is the near-side guard.
func ValidateSetting(key, value string) error {
	if !settingKeyRe.MatchString(key) || len(key) > 64 {
		return fmt.Errorf("invalid setting key %q", key)
	}
	if len(value) > 256 {
		return fmt.Errorf("value too long")
	}
	if !settingValueRe.MatchString(value) {
		return fmt.Errorf("value contains unsupported characters")
	}
	// A leading dash would be read as an option rather than as the value.
	if len(value) > 0 && value[0] == '-' {
		return fmt.Errorf("value must not start with a dash")
	}
	return nil
}

// Settings returns MTProxyL's settable settings with their current values.
func (c *Client) Settings(ctx context.Context) ([]Setting, error) {
	out, err := c.run(ctx, "settings", "list", "--json")
	if err != nil {
		return nil, err
	}
	var list []Setting
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse settings: %w", err)
	}
	if list == nil {
		list = []Setting{}
	}
	return list, nil
}

// SetSetting changes one setting through the CLI, not by writing settings.conf:
// some keys carry side effects MTProxyL already handles (changing the port
// moves geoblock rules and restarts the container).
func (c *Client) SetSetting(ctx context.Context, key, value string) (string, error) {
	if err := ValidateSetting(key, value); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "settings", "set", key, value)
	return stripANSI(out), err
}
