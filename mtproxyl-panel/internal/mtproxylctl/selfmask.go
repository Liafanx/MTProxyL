package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// SelfmaskStatus is the output of `mtproxyl selfmask status --json`.
//
// Selfmask serves a real HTTPS decoy site from a private nginx so that probing
// the proxy's SNI looks like an ordinary website, while Telegram clients still
// get MTProto on the same port.
type SelfmaskStatus struct {
	Enabled         bool   `json:"enabled"`
	Domain          string `json:"domain"`
	SiteSource      string `json:"site_source"`
	SiteDir         string `json:"site_dir"`
	BackendPort     int    `json:"backend_port"`
	CertMode        string `json:"cert_mode"`
	AutoRenew       bool   `json:"auto_renew"`
	NginxConf       string `json:"nginx_conf"`
	NginxConfExists bool   `json:"nginx_conf_exists"`
	CertFound       bool   `json:"cert_found"`
	PQNginxActive   bool   `json:"pq_nginx_active"`
}

// SelfmaskStatus reports the current decoy-site configuration.
func (c *Client) SelfmaskStatus(ctx context.Context) (*SelfmaskStatus, error) {
	out, err := c.run(ctx, "selfmask", "status", "--json")
	if err != nil {
		return nil, err
	}
	var st SelfmaskStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse selfmask output: %w", err)
	}
	return &st, nil
}

// SelfmaskVerify runs a live handshake check against the decoy site.
func (c *Client) SelfmaskVerify(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "verify")
	return stripANSI(out), err
}

// SelfmaskDisable tears the decoy site down.
func (c *Client) SelfmaskDisable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "disable")
	return stripANSI(out), err
}

// SelfmaskParam is one entry of the settable-parameter catalog.
type SelfmaskParam struct {
	Key         string `json:"key"`
	Validator   string `json:"validator"`
	Description string `json:"description"`
	Value       string `json:"value"`
}

// selfmaskKeyRe bounds parameter names, which become CLI arguments.
var selfmaskKeyRe = regexp.MustCompile(`^SELFMASK_[A-Z0-9_]{1,63}$`)

// selfmaskValueRe allows what real values look like: domains, emails, URLs,
// template names, ports and booleans.
var selfmaskValueRe = regexp.MustCompile(`^[A-Za-z0-9_.:/@%+-]*$`)

// ValidateSelfmaskParam checks a key/value pair before it reaches the CLI.
func ValidateSelfmaskParam(key, value string) error {
	if !selfmaskKeyRe.MatchString(key) {
		return fmt.Errorf("invalid parameter name %q", key)
	}
	if len(value) > 512 {
		return fmt.Errorf("value too long")
	}
	if !selfmaskValueRe.MatchString(value) {
		return fmt.Errorf("value contains unsupported characters")
	}
	// A leading dash would be read as an option rather than as the value.
	if strings.HasPrefix(value, "-") {
		return fmt.Errorf("value must not start with a dash")
	}
	return nil
}

// SelfmaskParams returns the settable parameters with their current values.
func (c *Client) SelfmaskParams(ctx context.Context) ([]SelfmaskParam, error) {
	out, err := c.run(ctx, "selfmask", "settable")
	if err != nil {
		return nil, err
	}
	var list []SelfmaskParam
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse selfmask params: %w", err)
	}
	if list == nil {
		list = []SelfmaskParam{}
	}
	return list, nil
}

// SetSelfmaskParam stores a parameter without reprovisioning the site.
func (c *Client) SetSelfmaskParam(ctx context.Context, key, value string) (string, error) {
	if err := ValidateSelfmaskParam(key, value); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "selfmask", "set", key, value)
	return stripANSI(out), err
}

// SelfmaskApply provisions the decoy site from the stored parameters.
//
// This is the non-interactive counterpart of MTProxyL's `selfmask setup`
// wizard: the wizard would take its own defaults under the assume-yes bypass
// and ignore whatever was chosen in the UI, so the panel sets parameters first
// and applies them here.
func (c *Client) SelfmaskApply(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "apply")
	return stripANSI(out), err
}
