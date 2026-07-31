package mtproxylctl

import "testing"

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

	direct := UpstreamSpec{Name: "direct", Type: "direct", Weight: 1}
	if err := direct.Validate(); err != nil {
		t.Errorf("direct spec rejected: %v", err)
	}

	bad := map[string]UpstreamSpec{
		"empty name":        {Name: "", Type: "direct"},
		"name injection":    {Name: "a; id", Type: "direct"},
		"name leading dash": {Name: "-rf", Type: "direct"},
		"name with slash":   {Name: "../etc", Type: "direct"},
		"unknown type":      {Name: "x", Type: "http"},
		"negative weight":   {Name: "x", Type: "direct", Weight: -1},
		"huge weight":       {Name: "x", Type: "direct", Weight: 10001},
		"addr injection":    {Name: "x", Type: "socks5", Address: "1.2.3.4:1080; id"},
		"addr space":        {Name: "x", Type: "socks5", Address: "1.2.3.4 1080"},
		"pass injection":    {Name: "x", Type: "socks5", Address: "1.2.3.4:1080", Password: "$(id)"},
		"iface injection":   {Name: "x", Type: "socks5", Address: "1.2.3.4:1080", Iface: "eth0|id"},
		"socks5 no address": {Name: "x", Type: "socks5"},
	}
	for label, spec := range bad {
		if err := spec.Validate(); err == nil {
			t.Errorf("%s: accepted, want error", label)
		}
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
