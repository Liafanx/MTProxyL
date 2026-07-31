package telemt_config

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSectionsToTOMLRendersIntegersNotFloats(t *testing.T) {
	// Numbers decoded from Telemt's JSON API arrive as json.Number (decoder
	// with UseNumber). Integers must render as `443`, not `443.0`, and real
	// floats must stay floats.
	sections := map[string]interface{}{
		"server":   map[string]interface{}{"port": json.Number("443")},
		"timeouts": map[string]interface{}{"client_handshake": json.Number("15")},
		"ratios":   map[string]interface{}{"x": json.Number("1.5")},
	}
	text, err := SectionsToTOML(sections)
	if err != nil {
		t.Fatalf("SectionsToTOML: %v", err)
	}
	if strings.Contains(text, "443.0") || strings.Contains(text, "15.0") {
		t.Fatalf("integer rendered as float:\n%s", text)
	}
	if !strings.Contains(text, "port = 443") {
		t.Fatalf("missing integer port:\n%s", text)
	}
	if !strings.Contains(text, "x = 1.5") {
		t.Fatalf("real float lost:\n%s", text)
	}
}

func TestSectionsToTOMLAndBack(t *testing.T) {
	sections := map[string]interface{}{
		"general":    map[string]interface{}{"use_middle_proxy": true, "ad_tag": "abc"},
		"censorship": map[string]interface{}{"tls_domain": "www.google.com"},
	}
	text, err := SectionsToTOML(sections)
	if err != nil {
		t.Fatalf("SectionsToTOML: %v", err)
	}
	if !strings.Contains(text, "[general]") || !strings.Contains(text, "tls_domain") {
		t.Fatalf("unexpected TOML:\n%s", text)
	}

	back, err := TOMLToSections(text)
	if err != nil {
		t.Fatalf("TOMLToSections: %v", err)
	}
	g, ok := back["general"].(map[string]interface{})
	if !ok || g["ad_tag"] != "abc" {
		t.Fatalf("round-trip lost data: %#v", back)
	}
	if g["use_middle_proxy"] != true {
		t.Fatalf("round-trip lost bool type: %#v", g["use_middle_proxy"])
	}
}

func TestTOMLToSectionsRejectsInvalid(t *testing.T) {
	if _, err := TOMLToSections("this is = = not toml"); err == nil {
		t.Fatal("expected parse error")
	}
}

func TestTOMLToSectionsEmptyReturnsNonNilMap(t *testing.T) {
	m, err := TOMLToSections("")
	if err != nil {
		t.Fatalf("empty doc: %v", err)
	}
	if m == nil {
		t.Fatal("expected non-nil empty map for empty document")
	}
}
