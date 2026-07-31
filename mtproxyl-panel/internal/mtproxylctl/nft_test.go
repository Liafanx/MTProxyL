package mtproxylctl

import "testing"

func TestValidateNftParamRejectsInjection(t *testing.T) {
	// Key and value both become arguments to a sudo-invoked command.
	bad := []struct{ key, value string }{
		{"NFT_IOS_RATE; rm -rf /", "1/second"},
		{"nft_ios_rate", "1/second"}, // lowercase is not a real key
		{"", "1/second"},             // empty
		{"N", "1/second"},            // too short
		{"NFT_IOS_RATE", "1/second; id"},
		{"NFT_IOS_RATE", "$(id)"},
		{"NFT_IOS_RATE", "`id`"},
		{"NFT_IOS_RATE", "a b"}, // whitespace
		{"NFT_IOS_RATE", "a\nb"},
		{"NFT_IOS_RATE", "--flag"}, // would be read as an option
		{"NFT_IOS_RATE", "x'y"},
		{"NFT_IOS_RATE", `x"y`},
		{"NFT_IOS_RATE", "x|y"},
		{"NFT_IOS_RATE", "x&y"},
		{"NFT_IOS_RATE", "x>y"},
	}
	for _, c := range bad {
		if err := ValidateNftParam(c.key, c.value); err == nil {
			t.Errorf("ValidateNftParam(%q, %q) = nil, want error", c.key, c.value)
		}
	}
}

func TestValidateNftParamAcceptsRealValues(t *testing.T) {
	good := []struct{ key, value string }{
		{"NFT_IOS_RATE", "15/second"},
		{"NFT_OTHER_RATE", "54/minute"},
		{"NFT_METER_TIMEOUT", "60s"},
		{"IOS_KA_TIME", "60"},
		{"NFT_IOS_DETECT", "fingerprint"},
		{"NFT_OTHER_ACTION", "icmp-host-unreachable"},
		{"ZAPRET2_FWMARK", "0x40"},
		{"ZAPRET2_EXTRA_PORTS", "443,9000-9100"},
		{"NFT_IOS_LIMIT_ENABLED", "true"},
		{"IOS2_TARGET_PORT", ""}, // empty means "use the proxy port"
	}
	for _, c := range good {
		if err := ValidateNftParam(c.key, c.value); err != nil {
			t.Errorf("ValidateNftParam(%q, %q) = %v, want nil", c.key, c.value, err)
		}
	}
}

func TestValidateNftParamRejectsOverlongValue(t *testing.T) {
	long := make([]byte, 257)
	for i := range long {
		long[i] = 'a'
	}
	if err := ValidateNftParam("NFT_IOS_RATE", string(long)); err == nil {
		t.Error("overlong value accepted")
	}
}

func TestNftActionAllowlist(t *testing.T) {
	for _, a := range []NftAction{NftApply, NftSmart, NftIos1On, Zapret2Install, Zapret2Stop} {
		if !ValidNftAction(a) {
			t.Errorf("%q should be allowed", a)
		}
	}
	for _, a := range []NftAction{"", "set", "settable", "status", "apply; id", "../../bin/sh", "extra-add"} {
		if ValidNftAction(NftAction(a)) {
			t.Errorf("%q should NOT be allowed", a)
		}
	}
}

func TestNftPresetRejectsUnknown(t *testing.T) {
	c := newStubClient(t)
	if _, err := c.NftPreset(t.Context(), "evil"); err == nil {
		t.Error("unknown preset accepted")
	}
}
