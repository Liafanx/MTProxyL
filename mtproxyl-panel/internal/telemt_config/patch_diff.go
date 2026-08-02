package telemt_config

import (
	"encoding/json"
	"reflect"
)

// ChangedSections keeps only the top-level sections whose contents differ from
// the current ones.
//
// In API mode the editor is filled from GET /v1/config, which reports the
// engine's *effective* configuration — every key, including the hundreds the
// operator never set. Sending all of that back as a patch would write those
// defaults into the config file explicitly, freezing them at today's values so
// they stop following engine upgrades. That is how the config turns into a
// wall of settings nobody chose.
//
// The API takes a sparse patch keyed by section, so the fix is to submit only
// the sections that actually changed. Filtering is done per section rather
// than per key on purpose: the API contract documents sparseness at the top
// level only, and dropping unchanged keys inside a section would silently
// erase them if the engine replaces sections wholesale.
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
//
// Round-tripping through JSON normalises the numeric types: the same port
// arrives as json.Number from the API and may be int64 after TOML parsing, and
// reflect.DeepEqual would call those different and mark an untouched section
// as edited.
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
