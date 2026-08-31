package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// SelfmaskStatus is the output of `mtproxyl selfmask status --json`. Selfmask
// serves a real HTTPS decoy from a private nginx so probing the SNI looks like
// an ordinary website, while Telegram clients still get MTProto on that port.
type SelfmaskStatus struct {
	Enabled               bool   `json:"enabled"`
	Domain                string `json:"domain"`
	SiteSource            string `json:"site_source"`
	SiteDir               string `json:"site_dir"`
	BackendPort           int    `json:"backend_port"`
	CertMode              string `json:"cert_mode"`
	AutoRenew             bool   `json:"auto_renew"`
	NginxConf             string `json:"nginx_conf"`
	NginxConfExists       bool   `json:"nginx_conf_exists"`
	NginxCustomEnabled    bool   `json:"nginx_custom_enabled"`
	NginxCustomActive     bool   `json:"nginx_custom_active"`
	NginxCustomFile       string `json:"nginx_custom_file"`
	NginxCustomFileExists bool   `json:"nginx_custom_file_exists"`
	CertFound             bool   `json:"cert_found"`
	PQNginxActive         bool   `json:"pq_nginx_active"`
	// PQSource, PQAvailable и PQSystem описывают, чем проверять домен на
	// постквантовый обмен ключами: системным OpenSSL 3.5.0+, нашей сборкой,
	// или нечем — тогда панель предлагает её поставить.
	PQSource    string `json:"pq_source"`
	PQAvailable bool   `json:"pq_available"`
	PQSystem    bool   `json:"pq_system"`
	// PrevSaved/PrevDomain describe the settings snapshot taken when Selfmask
	// was enabled. Disabling restores it, so the UI can name the fake SNI that
	// is about to come back instead of promising a vague "previous setup".
	PrevSaved  bool   `json:"prev_saved"`
	PrevDomain string `json:"prev_domain"`
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

// SelfmaskNginxConfig returns the saved custom config, or the generated config
// before custom mode has been enabled for the first time.
func (c *Client) SelfmaskNginxConfig(ctx context.Context) (string, error) {
	return c.run(ctx, "selfmask", "nginx-config", "show")
}

// WriteSelfmaskNginxConfig validates and atomically replaces the custom file.
func (c *Client) WriteSelfmaskNginxConfig(ctx context.Context, content string) (string, error) {
	if content == "" || len(content) > 2<<20 {
		return "", fmt.Errorf("nginx config size must be between 1 byte and 2 MiB")
	}
	out, err := c.runWithStdin(ctx, content, "selfmask", "nginx-config", "write")
	return stripANSI(out), err
}

// SetSelfmaskNginxCustom switches between the generated and user-owned files.
func (c *Client) SetSelfmaskNginxCustom(ctx context.Context, enabled bool) (string, error) {
	action := "off"
	if enabled {
		action = "on"
	}
	out, err := c.run(ctx, "selfmask", "nginx-config", action)
	return stripANSI(out), err
}

// TestSelfmaskNginxConfig runs nginx -t against the saved custom file.
func (c *Client) TestSelfmaskNginxConfig(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "nginx-config", "test")
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

// SelfmaskApply provisions the decoy site from the stored parameters — the
// non-interactive counterpart of the `selfmask setup` wizard, which under
// assume-yes would take its own defaults instead of the UI's.
func (c *Client) SelfmaskApply(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "apply")
	return stripANSI(out), err
}

// InstallPQTools installs the bundled PQ OpenSSL/nginx build. Needed only where
// the system OpenSSL predates 3.5.0 and has no X25519MLKEM768.
func (c *Client) InstallPQTools(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "pq-install")
	return stripANSI(out), err
}
