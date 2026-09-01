package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// ── Geoblock ────────────────────────────────────────────────────────────────

// GeoblockStatus is the output of `mtproxyl geoblock list --json`.
type GeoblockStatus struct {
	Mode           string   `json:"mode"`
	RulesActive    bool     `json:"rules_active"`
	PortsMatch     bool     `json:"ports_match"`
	ServiceEnabled bool     `json:"service_enabled"`
	Countries      []string `json:"countries"`
}

// countryCodeRe matches the two-letter codes MTProxyL accepts. The code is
// passed to a sudo-invoked command, so it is validated by shape.
var countryCodeRe = regexp.MustCompile(`^[a-zA-Z]{2}$`)

// ValidateCountryCode checks a country code before it reaches the CLI.
func ValidateCountryCode(code string) error {
	if !countryCodeRe.MatchString(code) {
		return fmt.Errorf("invalid country code %q", code)
	}
	return nil
}

func ValidateGeoblockMode(mode string) error {
	if mode != "blacklist" && mode != "whitelist" {
		return fmt.Errorf("invalid geoblock mode %q", mode)
	}
	return nil
}

// GeoblockList returns the currently blocked countries.
func (c *Client) GeoblockList(ctx context.Context) (*GeoblockStatus, error) {
	out, err := c.run(ctx, "geoblock", "list", "--json")
	if err != nil {
		return nil, err
	}
	var st GeoblockStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse geoblock list: %w", err)
	}
	if st.Countries == nil {
		st.Countries = []string{}
	}
	return &st, nil
}

// GeoblockAdd blocks a country. Adding downloads that country's CIDR ranges,
// so it can take a while on the first call.
func (c *Client) GeoblockAdd(ctx context.Context, code string) (string, error) {
	if err := ValidateCountryCode(code); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "geoblock", "add", strings.ToLower(code))
	return stripANSI(out), err
}

// GeoblockRemove unblocks a country.
func (c *Client) GeoblockRemove(ctx context.Context, code string) (string, error) {
	if err := ValidateCountryCode(code); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "geoblock", "remove", strings.ToLower(code))
	return stripANSI(out), err
}

func (c *Client) GeoblockSetMode(ctx context.Context, mode string) (string, error) {
	if err := ValidateGeoblockMode(mode); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "geoblock", "mode", mode)
	return stripANSI(out), err
}

func (c *Client) GeoblockReapply(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "geoblock", "reapply")
	return stripANSI(out), err
}

// ── Upstreams ───────────────────────────────────────────────────────────────

// Upstream is one outbound route. The password is deliberately absent: the CLI
// reports only whether one is set.
type Upstream struct {
	Name        string `json:"name"`
	Type        string `json:"type"`
	Address     string `json:"address"`
	User        string `json:"user"`
	HasPassword bool   `json:"has_password"`
	Weight      int    `json:"weight"`
	Iface       string `json:"iface"`
	// Scopes is the engine's comma-separated route tag list. Empty means the
	// route serves requests that carry no scope — see UpstreamSpec.Scopes.
	Scopes  string `json:"scopes"`
	Enabled bool   `json:"enabled"`
}

// upstreamNameRe bounds route names, which become CLI arguments.
var upstreamNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)

// upstreamFieldRe rejects whitespace and shell metacharacters in the remaining
// free-form fields (address, credentials, interface).
var upstreamFieldRe = regexp.MustCompile(`^[A-Za-z0-9_.:@/+=-]*$`)

// upstreamScopesRe matches the normalized tag list: comma-separated, no spaces.
var upstreamScopesRe = regexp.MustCompile(`^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$`)

// upstreamMaxWeight mirrors the engine's u16 weight field.
const upstreamMaxWeight = 65535

// UpstreamTypes lists the transports the engine accepts for a route.
var UpstreamTypes = []string{"direct", "socks5", "socks4", "shadowsocks"}

// UpstreamSpec describes a route to create.
type UpstreamSpec struct {
	Name string `json:"name"`
	Type string `json:"type"`
	// Address carries host:port for socks4/socks5 and the ss:// URL for
	// shadowsocks — the CLI picks the right config key from the type.
	Address  string `json:"address"`
	User     string `json:"user"`
	Password string `json:"password"`
	Weight   int    `json:"weight"`
	Iface    string `json:"iface"`
	// Scopes filters which requests may use this route. A request carrying a
	// scope only reaches routes tagged with it; a request without one only
	// reaches routes with empty Scopes.
	Scopes string `json:"scopes"`
}

// NormalizeScopes turns "me, fetch" into "me,fetch". The engine trims spaces
// when matching, but the stored value should not depend on how it was typed.
func NormalizeScopes(raw string) string {
	parts := strings.Split(raw, ",")
	out := parts[:0]
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, ",")
}

// Validate checks every field that becomes a command argument.
func (s UpstreamSpec) Validate() error {
	if !upstreamNameRe.MatchString(s.Name) {
		return fmt.Errorf("invalid upstream name %q", s.Name)
	}
	if !slices.Contains(UpstreamTypes, s.Type) {
		return fmt.Errorf("type must be one of %s", strings.Join(UpstreamTypes, ", "))
	}
	if s.Weight < 0 || s.Weight > upstreamMaxWeight {
		return fmt.Errorf("weight out of range")
	}
	for label, v := range map[string]string{
		"address":  s.Address,
		"user":     s.User,
		"password": s.Password,
		"iface":    s.Iface,
	} {
		if len(v) > 256 {
			return fmt.Errorf("%s too long", label)
		}
		if !upstreamFieldRe.MatchString(v) {
			return fmt.Errorf("%s contains unsupported characters", label)
		}
		// Same reason as for nft values: a leading dash would be taken as an
		// option by the command rather than as this field's value.
		if strings.HasPrefix(v, "-") {
			return fmt.Errorf("%s must not start with a dash", label)
		}
	}
	if s.Scopes != "" {
		if len(s.Scopes) > 256 {
			return fmt.Errorf("scopes too long")
		}
		if !upstreamScopesRe.MatchString(s.Scopes) {
			return fmt.Errorf("scopes must be comma-separated tags of A-Z, 0-9, _, ., -")
		}
	}
	switch s.Type {
	case "socks4", "socks5":
		if s.Address == "" {
			return fmt.Errorf("%s upstream needs an address", s.Type)
		}
	case "shadowsocks":
		// The CLI enforces the same rule, but rejecting here keeps the panel
		// from reporting a generic command failure for a fixable input.
		if !strings.HasPrefix(s.Address, "ss://") {
			return fmt.Errorf("shadowsocks upstream needs an ss:// URL")
		}
		if strings.Contains(s.Address, "plugin=") {
			return fmt.Errorf("shadowsocks plugins are not supported")
		}
	}
	return nil
}

// ValidateUpstreamName checks a name for the commands that take only a name.
func ValidateUpstreamName(name string) error {
	if !upstreamNameRe.MatchString(name) {
		return fmt.Errorf("invalid upstream name %q", name)
	}
	return nil
}

// UpstreamList returns the configured outbound routes.
func (c *Client) UpstreamList(ctx context.Context) ([]Upstream, error) {
	out, err := c.run(ctx, "upstream", "list", "--json")
	if err != nil {
		return nil, err
	}
	var list []Upstream
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse upstream list: %w", err)
	}
	if list == nil {
		list = []Upstream{}
	}
	return list, nil
}

// UpstreamAdd creates a route.
func (c *Client) UpstreamAdd(ctx context.Context, s UpstreamSpec) (string, error) {
	s.Scopes = NormalizeScopes(s.Scopes)
	if err := s.Validate(); err != nil {
		return "", err
	}
	// Positional order matches the CLI:
	// name type address [user] [pass] [weight] [iface] [scopes]
	out, err := c.run(ctx, "upstream", "add", s.Name, s.Type, s.Address,
		s.User, s.Password, strconv.Itoa(s.Weight), s.Iface, s.Scopes)
	return stripANSI(out), err
}

// UpstreamRemove deletes a route by name.
func (c *Client) UpstreamRemove(ctx context.Context, name string) (string, error) {
	if err := ValidateUpstreamName(name); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "upstream", "remove", name)
	return stripANSI(out), err
}

// UpstreamToggle enables or disables a route.
func (c *Client) UpstreamToggle(ctx context.Context, name string, enable bool) (string, error) {
	if err := ValidateUpstreamName(name); err != nil {
		return "", err
	}
	action := "disable"
	if enable {
		action = "enable"
	}
	out, err := c.run(ctx, "upstream", action, name)
	return stripANSI(out), err
}

// UpstreamTest probes a route's reachability.
func (c *Client) UpstreamTest(ctx context.Context, name string) (string, error) {
	if err := ValidateUpstreamName(name); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "upstream", "test", name)
	return stripANSI(out), err
}
