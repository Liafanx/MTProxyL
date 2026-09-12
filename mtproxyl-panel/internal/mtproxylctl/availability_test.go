package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestAvailabilityHistory(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "mtproxyl.sh")
	body := `#!/bin/sh
if [ "$1" = availability ] && [ "$2" = history ]; then
  echo '{"limit":1000,"points":[{"checked_at":"2026-09-12T00:00:00Z","percentage":75,"success_probes":18,"total_probes":24}]}'
  exit 0
fi
exit 1
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	client := New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})
	history, err := client.AvailabilityHistory(context.Background())
	if err != nil {
		t.Fatalf("history failed: %v", err)
	}
	if history.Limit != 1000 {
		t.Fatalf("limit = %d, want 1000", history.Limit)
	}
	if got := string(history.Points); got != `[{"checked_at":"2026-09-12T00:00:00Z","percentage":75,"success_probes":18,"total_probes":24}]` {
		t.Fatalf("points = %s", got)
	}
}
