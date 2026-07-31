package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
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

// SelfmaskSetup provisions (or re-provisions) the decoy site.
//
// Setup is a wizard: with MTPROXYL_ASSUME_YES it takes every prompt's default
// rather than any values chosen in the UI. Callers must treat this as
// "install with defaults", and a caller wanting specific settings should
// configure them through MTProxyL directly until the script grows flags.
func (c *Client) SelfmaskSetup(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "selfmask", "setup")
	return stripANSI(out), err
}
