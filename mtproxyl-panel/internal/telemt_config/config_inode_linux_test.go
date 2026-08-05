//go:build linux

package telemt_config

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// TestSaveConfigPreservesInode is the regression test for the ownership flip:
// SaveConfig must rewrite the existing inode in place, not replace it with a
// new file. A new inode would be owned by the (unprivileged) panel user and
// would silently lock Telemt out of its own config. Same inode => owner, group
// and permission bits are preserved automatically.
func TestSaveConfigPreservesInode(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")

	if err := os.WriteFile(cfgPath, []byte("port = 443\n"), 0o640); err != nil {
		t.Fatalf("seed config: %v", err)
	}

	before, err := inodeOf(cfgPath)
	if err != nil {
		t.Fatalf("stat before: %v", err)
	}
	beforeMode := modeOf(t, cfgPath)

	if _, err := SaveConfig(cfgPath, "port = 8443\n"); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	after, err := inodeOf(cfgPath)
	if err != nil {
		t.Fatalf("stat after: %v", err)
	}
	if before != after {
		t.Fatalf("inode changed: before=%d after=%d (file was replaced, not rewritten in place)", before, after)
	}
	if mode := modeOf(t, cfgPath); mode != beforeMode {
		t.Fatalf("permission bits changed: before=%o after=%o", beforeMode, mode)
	}
}

func inodeOf(path string) (uint64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	return info.Sys().(*syscall.Stat_t).Ino, nil
}

func modeOf(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	return info.Mode().Perm()
}
