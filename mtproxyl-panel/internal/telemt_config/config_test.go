package telemt_config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSaveConfigWritesContentAndBackup verifies the happy path: the new content
// lands in the config file and the previous content is preserved in a backup.
func TestSaveConfigWritesContentAndBackup(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	original := "port = 443\nname = \"old\"\n"
	if err := os.WriteFile(cfgPath, []byte(original), 0o600); err != nil {
		t.Fatalf("seed config: %v", err)
	}

	updated := "port = 8443\nname = \"new\"\n"
	hash, err := SaveConfig(cfgPath, updated)
	if err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	if hash == "" {
		t.Fatal("expected non-empty hash")
	}

	got, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if string(got) != updated {
		t.Fatalf("config content = %q, want %q", got, updated)
	}
	if want := calculateHash([]byte(updated)); hash != want {
		t.Fatalf("hash = %s, want %s", hash, want)
	}

	// A backup holding the original content must exist alongside the config.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	var backupFound bool
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), "config.toml.backup.") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read backup: %v", err)
		}
		if string(data) == original {
			backupFound = true
		}
	}
	if !backupFound {
		t.Fatal("no backup containing the original content was created")
	}
}

// TestSaveConfigCreatesMissingFile ensures a fresh file is created when the
// config does not exist yet (nothing to preserve in that case).
func TestSaveConfigCreatesMissingFile(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	content := "port = 443\n"
	if _, err := SaveConfig(cfgPath, content); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	got, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if string(got) != content {
		t.Fatalf("config content = %q, want %q", got, content)
	}
}
