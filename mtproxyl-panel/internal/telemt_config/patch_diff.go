package telemt_config

import (
	"encoding/json"
	"reflect"
)

// ChangedSections keeps only the top-level sections whose contents differ.
// In API mode the editor is filled from the engine's *effective* config, so
// sending it back would freeze hundreds of defaults into the file explicitly.
// Filtering is per section, not per key: the API documents sparseness at the
// top level only, and dropping keys inside a section could erase them.
func ChangedSections(submitted, current map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(submitted))
	for name, value := range submitted {
		if cur, ok := current[name]; ok && equalJSON(value, cur) {
			continue
		}
		out[name] = value
	}
	return out
}

// equalJSON compares two decoded TOML/JSON values for semantic equality.
// The JSON round-trip normalises numeric types: the same port arrives as
// json.Number from the API and int64 from TOML, and DeepEqual would differ.
func equalJSON(a, b interface{}) bool {
	if reflect.DeepEqual(a, b) {
		return true
	}
	na, err := json.Marshal(a)
	if err != nil {
		return false
	}
	nb, err := json.Marshal(b)
	if err != nil {
		return false
	}
	if string(na) == string(nb) {
		return true
	}
	// Compare re-decoded values so that 443 and "443"-as-json.Number, or maps
	// whose keys were inserted in a different order, still match.
	var da, db interface{}
	if json.Unmarshal(na, &da) != nil || json.Unmarshal(nb, &db) != nil {
		return false
	}
	return reflect.DeepEqual(da, db)
}
