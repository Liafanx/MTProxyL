package telemt_config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSaveConfigFileWritesInPlaceAndBacksUp(t *testing.T) {
	dir := t.TempDir()
	backupDir := t.TempDir()
	cfg := filepath.Join(dir, "telemt.toml")
	if err := os.WriteFile(cfg, []byte("port = 443\n"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if err := SaveConfigFile(cfg, "port = 8443\n", backupDir); err != nil {
		t.Fatalf("SaveConfigFile: %v", err)
	}

	got, _ := os.ReadFile(cfg)
	if string(got) != "port = 8443\n" {
		t.Fatalf("content = %q", got)
	}
	entries, _ := os.ReadDir(backupDir)
	var found bool
	for _, e := range entries {
		data, _ := os.ReadFile(filepath.Join(backupDir, e.Name()))
		if string(data) == "port = 443\n" {
			found = true
		}
	}
	if !found {
		t.Fatal("no backup with original content in backupDir")
	}
}

func TestSaveConfigFileRejectsInvalidTOML(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "telemt.toml")
	os.WriteFile(cfg, []byte("port = 443\n"), 0o644)
	err := SaveConfigFile(cfg, "= = bad", dir)
	if err == nil || !strings.Contains(err.Error(), "TOML") {
		t.Fatalf("expected TOML validation error, got %v", err)
	}
}
