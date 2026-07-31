package config

import "testing"

func TestEffectiveConfigEditModeDefaultsToAPI(t *testing.T) {
	if got := (TelemtConfig{}).EffectiveConfigEditMode(); got != "api" {
		t.Fatalf("empty mode = %q, want \"api\"", got)
	}
	if got := (TelemtConfig{ConfigEditMode: "file"}).EffectiveConfigEditMode(); got != "file" {
		t.Fatalf("file mode = %q, want \"file\"", got)
	}
	if got := (TelemtConfig{ConfigEditMode: "API"}).EffectiveConfigEditMode(); got != "api" {
		t.Fatalf("uppercase API = %q, want normalized \"api\"", got)
	}
	if got := (TelemtConfig{ConfigEditMode: "garbage"}).EffectiveConfigEditMode(); got != "api" {
		t.Fatalf("unknown mode = %q, want fallback \"api\"", got)
	}
	if got := (TelemtConfig{ConfigEditMode: "FILE"}).EffectiveConfigEditMode(); got != "file" {
		t.Fatalf("uppercase FILE = %q, want normalized \"file\"", got)
	}
	if got := (TelemtConfig{ConfigEditMode: "  file  "}).EffectiveConfigEditMode(); got != "file" {
		t.Fatalf("padded file = %q, want trimmed \"file\"", got)
	}
}
