//go:build linux

package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestWarpTimeoutStopsScannerChildren(t *testing.T) {
	dir := t.TempDir()
	script, marker := filepath.Join(dir, "cli"), filepath.Join(dir, "survived")
	body := "#!/bin/bash\ntimeout --foreground 10 bash -c 'sleep 0.5; touch \"" + marker + "\"' &\nwait\n"
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script, CommandTimeout: "100ms"})
	if _, err := c.WarpScan(context.Background()); err == nil {
		t.Fatal("expected timeout")
	}
	time.Sleep(650 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("scanner survived cancellation: %v", err)
	}
}
