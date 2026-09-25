package mtproxylctl

import "testing"

func TestValidateShapingConfig(t *testing.T) {
	base := ShapingConfig{
		Mode: "dynamic", ChannelMbps: 1000, ReservePercent: 10, ExpectedUsers: 10,
		ManualTotalMbps: 900, ManualIPMbps: 90,
		ProfileExempt: []string{"trusted"}, IPExempt: []string{"203.0.113.1", "198.51.100.0/24"},
	}
	if err := ValidateShapingConfig(base); err != nil {
		t.Fatalf("valid config: %v", err)
	}
	bad := base
	bad.ExpectedUsers = 1
	if err := ValidateShapingConfig(bad); err == nil {
		t.Fatal("expected users below safe floor accepted")
	}
	bad = base
	bad.IPExempt = []string{"2001:db8::1"}
	if err := ValidateShapingConfig(bad); err == nil {
		t.Fatal("IPv6 accepted")
	}
	bad = base
	bad.ProfileExempt = []string{"../../root"}
	if err := ValidateShapingConfig(bad); err == nil {
		t.Fatal("invalid profile accepted")
	}
}
