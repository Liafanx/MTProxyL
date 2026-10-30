package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestSetSecretNote(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	// Аргументы по одному в строке: видно, что заметка ушла одним argv.
	body := "#!/bin/sh\nfor a in \"$@\"; do echo \"[$a]\"; done\n"
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
	out, err := c.SetSecretNote(context.Background(), "alice", " Иван | тел\n123 ")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "[Иван   тел 123]") {
		t.Fatalf("note argv: %q", out)
	}
	out, err = c.SetSecretNote(context.Background(), "alice", "")
	if err != nil || !strings.Contains(out, "[-]") {
		t.Fatalf("clear: %q %v", out, err)
	}
	if _, err := c.SetSecretNote(context.Background(), "alice", strings.Repeat("я", 201)); err == nil {
		t.Fatal("long note accepted")
	}
	if _, err := c.SetSecretNote(context.Background(), "a b", "x"); err == nil {
		t.Fatal("bad label accepted")
	}
}
