package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// WebStatus is the output of `mtproxyl web json`. WEB mode carries MTProto
// inside ordinary HTTPS for the "WEB" proxy type: the engine
// never terminates TLS, nginx does, and forwards plain HTTP/1.1 to a private
// listener.
type WebStatus struct {
	Enabled bool `json:"enabled"`
	// Layout is "shared" (one public port split by SNI) or "split" (WEB gets
	// its own port and the proxy keeps PROXY_PORT untouched).
	Layout      string `json:"layout"`
	PublicPort  int    `json:"public_port"`
	Domain      string `json:"domain"`
	Carrier     string `json:"carrier"`
	SecretMode  string `json:"secret_mode"`
	PublicAddr  string `json:"public_addr"`
	ListenPort  int    `json:"listen_port"`
	TLSPort     int    `json:"tls_port"`
	MTProxyPort int    `json:"mtproxy_port"`
	DecoyMode   string `json:"decoy_mode"`
	DecoyDir    string `json:"decoy_dir"`
	Debug       bool   `json:"debug"`
	// Problems is a semicolon-separated list of preflight blockers. Empty means
	// the mode can be switched on.
	Problems string `json:"problems"`
}

// WebStatus reports the current WEB proxy configuration.
func (c *Client) WebStatus(ctx context.Context) (*WebStatus, error) {
	out, err := c.run(ctx, "web", "json")
	if err != nil {
		return nil, err
	}
	var st WebStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse web output: %w", err)
	}
	return &st, nil
}

// WebEnable turns WEB mode on. It moves listeners and rewrites the nginx
// config, so it is slow enough to belong in the operation runner.
func (c *Client) WebEnable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "web", "enable")
	return stripANSI(out), err
}

// WebDisable turns WEB mode off and hands the public port back to the engine.
func (c *Client) WebDisable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "web", "disable")
	return stripANSI(out), err
}

// WebLinks returns the tg://webproxy links. The engine API does not expose
// them — its user links cover only classic, secure and TLS — so MTProxyL
// builds them itself.
func (c *Client) WebLinks(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "web", "links")
	return stripANSI(out), err
}

// WebParam is one entry of the settable-parameter catalog.
type WebParam struct {
	Key         string `json:"key"`
	Validator   string `json:"validator"`
	Description string `json:"desc"`
	Value       string `json:"value"`
}

// WebParams lists what the UI may change.
func (c *Client) WebParams(ctx context.Context) ([]WebParam, error) {
	out, err := c.run(ctx, "web", "settable")
	if err != nil {
		return nil, err
	}
	var params []WebParam
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &params); err != nil {
		return nil, fmt.Errorf("parse web params: %w", err)
	}
	return params, nil
}

// webKeyRe bounds parameter names, which become CLI arguments.
var webKeyRe = regexp.MustCompile(`^WEB_[A-Z0-9_]{1,63}$`)

// webValueRe allows what real values look like: domains, paths, URLs, ports,
// carrier names and booleans.
var webValueRe = regexp.MustCompile(`^[A-Za-z0-9_.:/@%+-]*$`)

// ValidateWebParam checks a key/value pair before it reaches the CLI.
func ValidateWebParam(key, value string) error {
	if !webKeyRe.MatchString(key) {
		return fmt.Errorf("invalid parameter name %q", key)
	}
	if len(value) > 512 {
		return fmt.Errorf("value too long")
	}
	if !webValueRe.MatchString(value) {
		return fmt.Errorf("value contains unsupported characters")
	}
	// A leading dash would be read as an option rather than as the value.
	if strings.HasPrefix(value, "-") {
		return fmt.Errorf("value must not start with a dash")
	}
	return nil
}

// WebSet stores one parameter. Applying it is a separate step: enabling
// rebuilds both the engine config and the nginx one.
func (c *Client) WebSet(ctx context.Context, key, value string) (string, error) {
	if err := ValidateWebParam(key, value); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "web", "set", key, value)
	return stripANSI(out), err
}
