package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestEngineCleanupPreviewAndApply(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	body := `#!/bin/sh
case "$*" in
  'engine cleanup --json') echo '{"candidates":[{"reference":"mtproxyl-telemt:3.5.4","id":"sha256:unused","size":"17MB"}]}' ;;
  'engine cleanup --yes') echo 'removed' ;;
  *) exit 9 ;;
esac
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
	p, err := c.EngineCleanupPreview(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Candidates) != 1 || p.Candidates[0].Reference != "mtproxyl-telemt:3.5.4" {
		t.Fatalf("preview: %+v", p)
	}
	out, err := c.EngineCleanup(context.Background())
	if err != nil || strings.TrimSpace(out) != "removed" {
		t.Fatalf("apply: %q %v", out, err)
	}
}

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
