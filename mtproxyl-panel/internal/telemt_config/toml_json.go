package telemt_config

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// SectionsToTOML renders a map of config sections (as returned by Telemt's
// GET /v1/config) into TOML text for the editor. Integer underscores are
// stripped to match the format Telemt parses (e.g. 8_443 -> 8443).
func SectionsToTOML(sections map[string]interface{}) (string, error) {
	out, err := toml.Marshal(normalizeJSONNumbers(sections))
	if err != nil {
		return "", fmt.Errorf("marshal sections: %w", err)
	}
	return removeIntegerUnderscores(string(out)), nil
}

// normalizeJSONNumbers converts json.Number values (produced by a JSON decoder
// with UseNumber) into concrete int64/float64 so the TOML marshaler renders
// integers as integers (443) and not as floats (443.0) or quoted strings.
// Integral numbers without a fraction or exponent become int64; everything
// else becomes float64. Without this, a port like 443 round-trips through the
// API as 443.0 and corrupts Telemt's config on save.
func normalizeJSONNumbers(v interface{}) interface{} {
	switch x := v.(type) {
	case map[string]interface{}:
		for k, vv := range x {
			x[k] = normalizeJSONNumbers(vv)
		}
		return x
	case []interface{}:
		for i, vv := range x {
			x[i] = normalizeJSONNumbers(vv)
		}
		return x
	case json.Number:
		s := x.String()
		if !strings.ContainsAny(s, ".eE") {
			if n, err := x.Int64(); err == nil {
				return n
			}
		}
		if f, err := x.Float64(); err == nil {
			return f
		}
		return s
	default:
		return v
	}
}

// TOMLToSections parses editor TOML text back into a generic section map
// suitable for a PATCH /v1/config body.
func TOMLToSections(content string) (map[string]interface{}, error) {
	var m map[string]interface{}
	if err := toml.Unmarshal([]byte(content), &m); err != nil {
		return nil, fmt.Errorf("parse sections: %w", err)
	}
	if m == nil {
		m = map[string]interface{}{}
	}
	return m, nil
}
