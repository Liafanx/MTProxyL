package mtproxylctl

import (
	"strings"
	"testing"
)

func TestValidateEngineTag(t *testing.T) {
	good := []string{"v3.4.25", "3.4.25", "v3.4.25-rc1", "latest"}
	for _, tag := range good {
		if err := ValidateEngineTag(tag); err != nil {
			t.Errorf("ValidateEngineTag(%q) = %v, ожидался nil", tag, err)
		}
	}
	bad := []string{
		"",
		"   ",
		"-3.4.25",
		"v3.4.25; rm -rf /",
		"../../etc/passwd",
		"v3.4.25 extra",
		"v" + strings.Repeat("9", 64),
	}
	for _, tag := range bad {
		if err := ValidateEngineTag(tag); err == nil {
			t.Errorf("ValidateEngineTag(%q) прошёл, ожидалась ошибка", tag)
		}
	}
}
