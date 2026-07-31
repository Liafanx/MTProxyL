package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// ── Geoblock ────────────────────────────────────────────────────────────────

// GeoblockStatus is the output of `mtproxyl geoblock list --json`.
type GeoblockStatus struct {
	Countries []string `json:"countries"`
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
	Enabled     bool   `json:"enabled"`
}

// upstreamNameRe bounds route names, which become CLI arguments.
var upstreamNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)

// upstreamFieldRe rejects whitespace and shell metacharacters in the remaining
// free-form fields (address, credentials, interface).
var upstreamFieldRe = regexp.MustCompile(`^[A-Za-z0-9_.:@/+=-]*$`)

// UpstreamSpec describes a route to create.
type UpstreamSpec struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Address  string `json:"address"`
	User     string `json:"user"`
	Password string `json:"password"`
	Weight   int    `json:"weight"`
	Iface    string `json:"iface"`
}

// Validate checks every field that becomes a command argument.
func (s UpstreamSpec) Validate() error {
	if !upstreamNameRe.MatchString(s.Name) {
		return fmt.Errorf("invalid upstream name %q", s.Name)
	}
	if s.Type != "direct" && s.Type != "socks5" {
		return fmt.Errorf("type must be direct or socks5")
	}
	if s.Weight < 0 || s.Weight > 10000 {
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
	if s.Type == "socks5" && s.Address == "" {
		return fmt.Errorf("socks5 upstream needs an address")
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
	if err := s.Validate(); err != nil {
		return "", err
	}
	// Positional order matches the CLI: name type address [user] [pass] [weight] [iface]
	out, err := c.run(ctx, "upstream", "add", s.Name, s.Type, s.Address,
		s.User, s.Password, strconv.Itoa(s.Weight), s.Iface)
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
