package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// ExpertParam is one entry of MTProxyL's telemt parameter catalog.
//
// The catalog is the authority on what may be tuned and how it is validated;
// the panel renders a field from Validator rather than repeating those rules.
type ExpertParam struct {
	Section     string `json:"section"`
	Key         string `json:"key"`
	Type        string `json:"type"`
	Default     string `json:"default"`
	HotReload   bool   `json:"hot_reload"`
	Validator   string `json:"validator"`
	Hint        string `json:"hint"`
	Description string `json:"description"`
	Override    string `json:"override"`
	HasOverride bool   `json:"has_override"`
}

// ExpertOverride is a value the user has set on top of the generated config.
type ExpertOverride struct {
	Section string `json:"section"`
	Key     string `json:"key"`
	Value   string `json:"value"`
}

// Section and key become CLI arguments, so both are matched against a shape.
// Sections are dotted lowercase ("general.links", "censorship.tls_fetch").
var (
	expertSectionRe = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`)
	expertKeyRe     = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	// Values cover integers, booleans, enum words, domains, URLs, addresses
	// and comma-separated lists.
	//
	// Brackets and quotes stay out deliberately. List-typed parameters
	// (string[] in MTProxyL's catalog, e.g. [server.api] whitelist) are
	// entered as a plain comma-separated list — the TOML array syntax is added
	// when the override is applied. Accepting a quote here would let a plain
	// string parameter produce key = "va"lue" and break the engine's config.
	expertValueRe = regexp.MustCompile(`^[A-Za-z0-9_,:/.@%+-]*$`)
)

// ValidateExpertParam checks a section/key/value triple before it reaches the
// CLI. MTProxyL validates again against its catalog; this is the near-side guard.
func ValidateExpertParam(section, key, value string) error {
	if !expertSectionRe.MatchString(section) || len(section) > 64 {
		return fmt.Errorf("invalid section %q", section)
	}
	if !expertKeyRe.MatchString(key) || len(key) > 64 {
		return fmt.Errorf("invalid key %q", key)
	}
	if len(value) > 512 {
		return fmt.Errorf("value too long")
	}
	if !expertValueRe.MatchString(value) {
		return fmt.Errorf("value contains unsupported characters")
	}
	// A leading dash would be read as an option rather than as the value.
	if strings.HasPrefix(value, "-") {
		return fmt.Errorf("value must not start with a dash")
	}
	return nil
}

// ValidateExpertTarget checks a section/key pair for commands that take no value.
func ValidateExpertTarget(section, key string) error {
	return ValidateExpertParam(section, key, "")
}

// ExpertCatalog returns every tunable engine parameter with its current override.
func (c *Client) ExpertCatalog(ctx context.Context) ([]ExpertParam, error) {
	out, err := c.run(ctx, "expert", "list", "--catalog")
	if err != nil {
		return nil, err
	}
	var list []ExpertParam
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse expert catalog: %w", err)
	}
	if list == nil {
		list = []ExpertParam{}
	}
	return list, nil
}

// ExpertOverrides returns only the values the user has set.
func (c *Client) ExpertOverrides(ctx context.Context) ([]ExpertOverride, error) {
	out, err := c.run(ctx, "expert", "list", "--json")
	if err != nil {
		return nil, err
	}
	var list []ExpertOverride
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse expert overrides: %w", err)
	}
	if list == nil {
		list = []ExpertOverride{}
	}
	return list, nil
}

// SetExpertParam stores an override for one engine parameter.
//
// The write is deferred: rebuilding the engine config after every parameter
// would regenerate it and reload the proxy once per value. Callers save a batch
// and then call ApplyExpert once.
func (c *Client) SetExpertParam(ctx context.Context, section, key, value string) (string, error) {
	if err := ValidateExpertParam(section, key, value); err != nil {
		return "", err
	}
	if value == "" {
		return "", fmt.Errorf("value must not be empty")
	}
	out, err := c.run(ctx, "expert", "set", section, key, value, "--no-apply")
	return stripANSI(out), err
}

// ClearExpertParam removes one override, restoring the generated value.
// Like SetExpertParam it defers the rebuild.
func (c *Client) ClearExpertParam(ctx context.Context, section, key string) (string, error) {
	if err := ValidateExpertTarget(section, key); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "expert", "clear", section, key, "--no-apply")
	return stripANSI(out), err
}

// ApplyExpert regenerates the engine config and hot-reloads the proxy.
func (c *Client) ApplyExpert(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "expert", "apply")
	return stripANSI(out), err
}

// ── Super expert ────────────────────────────────────────────────────────────

// SuperExpertStatus describes the hand-authored engine config mode.
//
// While it is active MTProxyL stops generating the engine config, so the panel
// disables the settings that would be overwritten.
type SuperExpertStatus struct {
	Enabled    bool   `json:"enabled"`
	Active     bool   `json:"active"`
	File       string `json:"file"`
	FileExists bool   `json:"file_exists"`
	Size       int64  `json:"size"`
	Mtime      int64  `json:"mtime"`
}

// SuperExpertStatus reports whether the user owns the engine config.
func (c *Client) SuperExpertStatus(ctx context.Context) (*SuperExpertStatus, error) {
	out, err := c.run(ctx, "superexpert", "status", "--json")
	if err != nil {
		return nil, err
	}
	var st SuperExpertStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse superexpert status: %w", err)
	}
	return &st, nil
}

// SuperExpertRead returns the hand-authored config verbatim.
//
// The output is the file itself, so it is returned unchanged: stripping ANSI
// here would corrupt a config that legitimately contains such sequences.
func (c *Client) SuperExpertRead(ctx context.Context) (string, error) {
	return c.run(ctx, "superexpert", "show")
}

// SuperExpertWrite replaces the hand-authored config.
//
// The content goes over stdin rather than as an argument: it is multi-line TOML
// with quotes, which would be both awkward and risky to pass on a command line.
func (c *Client) SuperExpertWrite(ctx context.Context, content string) (string, error) {
	if strings.TrimSpace(content) == "" {
		return "", fmt.Errorf("config must not be empty")
	}
	out, err := c.runWithStdin(ctx, content, "superexpert", "write")
	return stripANSI(out), err
}

// SuperExpertEnable hands config ownership to the user.
func (c *Client) SuperExpertEnable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "superexpert", "on")
	return stripANSI(out), err
}

// SuperExpertDisable returns config ownership to MTProxyL. The file is kept.
func (c *Client) SuperExpertDisable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "superexpert", "off")
	return stripANSI(out), err
}

// ── Addons ──────────────────────────────────────────────────────────────────

// pqDomainRe bounds the domain (optionally with a port) passed to the check.
var pqDomainRe = regexp.MustCompile(`^[A-Za-z0-9.-]+(:[0-9]{1,5})?$`)

// ValidatePQDomain checks a domain before it reaches the CLI.
func ValidatePQDomain(domain string) error {
	if domain == "" {
		// Empty means "the current SNI domain" — MTProxyL resolves it itself.
		return nil
	}
	if len(domain) > 255 || !pqDomainRe.MatchString(domain) {
		return fmt.Errorf("invalid domain %q", domain)
	}
	if strings.HasPrefix(domain, "-") {
		return fmt.Errorf("domain must not start with a dash")
	}
	return nil
}

// PQCheck probes a domain for post-quantum key exchange support.
//
// iOS clients can hang on "Connecting…" against a FakeTLS domain without it,
// so this is worth checking before settling on someone else's domain.
func (c *Client) PQCheck(ctx context.Context, domain string) (string, error) {
	if err := ValidatePQDomain(domain); err != nil {
		return "", err
	}
	args := []string{"pq-check"}
	if domain != "" {
		args = append(args, domain)
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}
