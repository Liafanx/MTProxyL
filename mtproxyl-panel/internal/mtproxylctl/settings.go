package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
)

// Setting is one entry of `mtproxyl settings list --json`.
//
// These are MTProxyL's own settings — port, SNI domain, masking and so on —
// stored in settings.conf, not in the engine's config. In manager mode the
// engine's config.toml is mounted read-only into its container, so telemt
// cannot be asked to change any of this: MTProxyL regenerates the config from
// these values instead.
type Setting struct {
	Key         string `json:"key"`
	Validator   string `json:"validator"`
	Description string `json:"description"`
	Value       string `json:"value"`
}

// settingKeyRe matches the SHOUTY_SNAKE names MTProxyL uses for settings.
var settingKeyRe = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)

// settingValueRe covers ports, domains, hex tags, booleans and enum words.
//
// Brackets, quotes and whitespace stay out: none of the settable keys take a
// list, and a stray quote would end up inside settings.conf. Empty is allowed
// — it is how an ad tag or a pinned IP is cleared.
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

// SetSetting changes one setting.
//
// Some keys carry side effects MTProxyL already handles — changing the proxy
// port moves the geoblock rules and restarts the container — so the CLI is the
// only correct place to do this, not a direct write to settings.conf.
func (c *Client) SetSetting(ctx context.Context, key, value string) (string, error) {
	if err := ValidateSetting(key, value); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "settings", "set", key, value)
	return stripANSI(out), err
}
