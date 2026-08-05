package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// NftParam is one entry of MTProxyL's settable-parameter catalog.
type NftParam struct {
	Key         string `json:"key"`
	Validator   string `json:"validator"`
	Description string `json:"description"`
	Value       string `json:"value"`
}

// NftStatus is the output of `mtproxyl nft status --json`.
type NftStatus struct {
	Nft struct {
		Enabled       bool   `json:"enabled"`
		Mode          string `json:"mode"`
		ServiceActive bool   `json:"service_active"`
	} `json:"nft"`
	IosFixV1 struct {
		Enabled bool `json:"enabled"`
	} `json:"ios_fix_v1"`
	IosFixV2 struct {
		Enabled bool `json:"enabled"`
	} `json:"ios_fix_v2"`
	Zapret2 struct {
		Applied       bool `json:"applied"`
		ServiceActive bool `json:"service_active"`
	} `json:"zapret2"`
	MekoOpt struct {
		Applied bool `json:"applied"`
	} `json:"meko_opt"`
	Params []NftParam `json:"params"`
}

// nftParamKeyRe bounds what may be passed as a parameter name.
//
// The key becomes an argument to a sudo-invoked command, so it is matched
// against a shape rather than merely escaped. MTProxyL validates the key
// against its own catalog too; this is the near-side guard.
var nftParamKeyRe = regexp.MustCompile(`^[A-Z][A-Z0-9_]{1,63}$`)

// nftParamValueRe rejects anything that is not a plain scalar. Real values are
// rates ("15/second"), durations ("60s"), integers, booleans, enum words,
// hex marks ("0x40") and port lists ("443,9000-9100").
var nftParamValueRe = regexp.MustCompile(`^[A-Za-z0-9_,:/.-]*$`)

// ValidateNftParam checks a key/value pair before it reaches the CLI.
func ValidateNftParam(key, value string) error {
	if !nftParamKeyRe.MatchString(key) {
		return fmt.Errorf("invalid parameter name %q", key)
	}
	if len(value) > 256 {
		return fmt.Errorf("value too long")
	}
	if !nftParamValueRe.MatchString(value) {
		return fmt.Errorf("value contains unsupported characters")
	}
	// A leading dash would be parsed as an option by the command, not as a
	// value. Dashes are legitimate inside values ("icmp-host-unreachable",
	// "9000-9100"), so only the first character is restricted.
	if strings.HasPrefix(value, "-") {
		return fmt.Errorf("value must not start with a dash")
	}
	return nil
}

// NftStatus reports the limiter, iOS fixes, Zapret2 state and current parameters.
func (c *Client) NftStatus(ctx context.Context) (*NftStatus, error) {
	out, err := c.run(ctx, "nft", "status", "--json")
	if err != nil {
		return nil, err
	}
	var st NftStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse nft status: %w", err)
	}
	if st.Params == nil {
		st.Params = []NftParam{}
	}
	return &st, nil
}

// SetNftParam changes a stored parameter.
//
// It does not reapply kernel rules — MTProxyL keeps those steps separate, and
// so does the UI: the caller applies a preset afterwards.
func (c *Client) SetNftParam(ctx context.Context, key, value string) (string, error) {
	if err := ValidateNftParam(key, value); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "nft", "set", key, value)
	return stripANSI(out), err
}

// NftAction is a limiter/fix command that takes no arguments.
type NftAction string

const (
	NftApply        NftAction = "apply"
	NftRemove       NftAction = "remove"
	NftService      NftAction = "service"
	NftSmart        NftAction = "smart"
	NftIos1On       NftAction = "ios1"
	NftIos1Off      NftAction = "ios1-off"
	NftIos2On       NftAction = "ios2"
	NftIos2Off      NftAction = "ios2-off"
	Zapret2Install  NftAction = "zapret2"
	Zapret2Start    NftAction = "zapret2-start"
	Zapret2Stop     NftAction = "zapret2-stop"
	Zapret2Remove   NftAction = "zapret2-rm"
	Zapret2Wscale   NftAction = "zapret2-wscale"
	NftDropCounters NftAction = "drop"
)

// nftActions is the allowlist of subcommands the panel may invoke. A map keeps
// an arbitrary string from ever reaching the CLI.
var nftActions = map[NftAction]bool{
	NftApply: true, NftRemove: true, NftService: true, NftSmart: true,
	NftIos1On: true, NftIos1Off: true, NftIos2On: true, NftIos2Off: true,
	Zapret2Install: true, Zapret2Start: true, Zapret2Stop: true,
	Zapret2Remove: true, Zapret2Wscale: true, NftDropCounters: true,
}

// ValidNftAction reports whether a is a recognised action.
func ValidNftAction(a NftAction) bool { return nftActions[a] }

// RunNftAction executes one of the allowlisted limiter/fix commands.
//
// Several of these (smart, ios1, ios2, zapret2 install) are wizards in
// MTProxyL: under the assume-yes bypass they run with the values stored in
// nft-rules.conf, which is exactly what SetNftParam writes. So the UI flow is
// "set parameters, then apply".
func (c *Client) RunNftAction(ctx context.Context, a NftAction) (string, error) {
	if !ValidNftAction(a) {
		return "", fmt.Errorf("unknown nft action %q", a)
	}
	out, err := c.run(ctx, "nft", string(a))
	return stripANSI(out), err
}

// NftPreset switches the limiter between classic and smart.
func (c *Client) NftPreset(ctx context.Context, preset string) (string, error) {
	if preset != "classic" && preset != "smart" {
		return "", fmt.Errorf("unknown preset %q", preset)
	}
	out, err := c.run(ctx, "nft", "preset", preset)
	return stripANSI(out), err
}
