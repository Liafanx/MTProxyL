package mtproxylctl

import (
	"slices"
	"strings"
	"testing"
)

func TestValidateCountryCode(t *testing.T) {
	for _, c := range []string{"us", "DE", "ir"} {
		if err := ValidateCountryCode(c); err != nil {
			t.Errorf("ValidateCountryCode(%q) = %v, want nil", c, err)
		}
	}
	// The code becomes a CLI argument, so anything else must be refused.
	for _, c := range []string{"", "u", "usa", "u1", "us;id", "../x", "-r", "u s"} {
		if err := ValidateCountryCode(c); err == nil {
			t.Errorf("ValidateCountryCode(%q) = nil, want error", c)
		}
	}
}

func TestUpstreamSpecValidate(t *testing.T) {
	base := UpstreamSpec{Name: "warp", Type: "socks5", Address: "127.0.0.1:1080", Weight: 10}
	if err := base.Validate(); err != nil {
		t.Fatalf("valid spec rejected: %v", err)
	}

	// Every shape the engine documents must survive validation, or the panel
	// silently offers fewer route types than MTProxyL supports.
	good := map[string]UpstreamSpec{
		"direct":            {Name: "direct", Type: "direct", Weight: 1},
		"socks4 with id":    {Name: "s4", Type: "socks4", Address: "10.0.0.1:1080", User: "telemt"},
		"shadowsocks":       {Name: "ss", Type: "shadowsocks", Address: "ss://2022-blake3-aes-256-gcm:UEFTUw==@10.0.0.1:8388"},
		"max engine weight": {Name: "w", Type: "direct", Weight: 65535},
		"zero weight":       {Name: "z", Type: "direct", Weight: 0},
		"scoped":            {Name: "sc", Type: "direct", Scopes: "me,fetch,dc2"},
	}
	for label, spec := range good {
		if err := spec.Validate(); err != nil {
			t.Errorf("%s: rejected (%v), want accepted", label, err)
		}
	}

	bad := map[string]UpstreamSpec{
		"empty name":         {Name: "", Type: "direct"},
		"name injection":     {Name: "a; id", Type: "direct"},
		"name leading dash":  {Name: "-rf", Type: "direct"},
		"name with slash":    {Name: "../etc", Type: "direct"},
		"unknown type":       {Name: "x", Type: "http"},
		"negative weight":    {Name: "x", Type: "direct", Weight: -1},
		"weight above u16":   {Name: "x", Type: "direct", Weight: 65536},
		"addr injection":     {Name: "x", Type: "socks5", Address: "1.2.3.4:1080; id"},
		"addr space":         {Name: "x", Type: "socks5", Address: "1.2.3.4 1080"},
		"pass injection":     {Name: "x", Type: "socks5", Address: "1.2.3.4:1080", Password: "$(id)"},
		"iface injection":    {Name: "x", Type: "socks5", Address: "1.2.3.4:1080", Iface: "eth0|id"},
		"socks5 no address":  {Name: "x", Type: "socks5"},
		"socks4 no address":  {Name: "x", Type: "socks4"},
		"shadowsocks no url": {Name: "x", Type: "shadowsocks", Address: "10.0.0.1:8388"},
		"shadowsocks plugin": {Name: "x", Type: "shadowsocks", Address: "ss://m:p@10.0.0.1:8388?plugin=obfs"},
		"scopes injection":   {Name: "x", Type: "direct", Scopes: "me;id"},
		"scopes with space":  {Name: "x", Type: "direct", Scopes: "me fetch"},
	}
	for label, spec := range bad {
		if err := spec.Validate(); err == nil {
			t.Errorf("%s: accepted, want error", label)
		}
	}
}

func TestNormalizeScopes(t *testing.T) {
	cases := map[string]string{
		"me, fetch , dc2": "me,fetch,dc2",
		" a ,, b , ":      "a,b",
		"":                "",
		",,,":             "",
		"me":              "me",
	}
	for in, want := range cases {
		if got := NormalizeScopes(in); got != want {
			t.Errorf("NormalizeScopes(%q) = %q, want %q", in, got, want)
		}
	}
}

// UpstreamAdd normalizes before validating, so a list typed with spaces must
// reach the CLI rather than be rejected as malformed. The argument positions
// matter beyond that: the CLI reads scopes as the eighth argument after "add",
// so an omitted empty field would silently land the tags in "iface".
func TestUpstreamAddArguments(t *testing.T) {
	c := newStubClient(t)
	out, err := c.UpstreamAdd(t.Context(), UpstreamSpec{
		Name: "sc", Type: "direct", Weight: 10, Scopes: "me, fetch",
	})
	if err != nil {
		t.Fatalf("UpstreamAdd with spaced scopes failed: %v", err)
	}
	var args []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		args = append(args, strings.TrimPrefix(strings.TrimSpace(line), "arg="))
	}
	want := []string{"upstream", "add", "sc", "direct", "", "", "", "10", "", "me,fetch"}
	if !slices.Equal(args, want) {
		t.Errorf("args = %q, want %q", args, want)
	}
}

func TestValidateUpstreamName(t *testing.T) {
	if err := ValidateUpstreamName("warp-1.eu"); err != nil {
		t.Errorf("valid name rejected: %v", err)
	}
	for _, n := range []string{"", "-x", "a b", "a;id", "a/b", "a$b"} {
		if err := ValidateUpstreamName(n); err == nil {
			t.Errorf("ValidateUpstreamName(%q) = nil, want error", n)
		}
	}
}

// Validation must happen before the CLI is invoked; the stub exits non-zero for
// unknown commands, so a rejection here proves nothing was run.
func TestNetworkCommandsValidateBeforeRunning(t *testing.T) {
	c := newStubClient(t)
	ctx := t.Context()

	if _, err := c.GeoblockAdd(ctx, "us; id"); err == nil {
		t.Error("GeoblockAdd accepted an injection")
	}
	if _, err := c.UpstreamRemove(ctx, "a; id"); err == nil {
		t.Error("UpstreamRemove accepted an injection")
	}
	if _, err := c.UpstreamToggle(ctx, "../x", true); err == nil {
		t.Error("UpstreamToggle accepted a traversal name")
	}
	if _, err := c.SetNftParam(ctx, "NFT_IOS_RATE", "1/second; id"); err == nil {
		t.Error("SetNftParam accepted an injection")
	}
	if _, err := c.RunNftAction(ctx, NftAction("apply; id")); err == nil {
		t.Error("RunNftAction accepted an unlisted action")
	}
}
