package sysutil

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestInstallBinaryLeavesDestinationUntouchedOnCopyError(t *testing.T) {
	oldFileCopier := fileCopier
	t.Cleanup(func() {
		fileCopier = oldFileCopier
	})

	dir := t.TempDir()
	src := filepath.Join(dir, "src.bin")
	dst := filepath.Join(dir, "dst.bin")

	if err := os.WriteFile(src, []byte("new-binary"), 0o644); err != nil {
		t.Fatalf("write src: %v", err)
	}
	if err := os.WriteFile(dst, []byte("old-binary"), 0o644); err != nil {
		t.Fatalf("write dst: %v", err)
	}

	fileCopier = func(w io.Writer, r io.Reader) (int64, error) {
		if _, err := w.Write([]byte("partial")); err != nil {
			return 0, err
		}
		return int64(len("partial")), errors.New("copy failed")
	}

	err := InstallBinary(src, dst)
	if err == nil {
		t.Fatal("expected install to fail")
	}

	got, readErr := os.ReadFile(dst)
	if readErr != nil {
		t.Fatalf("read dst: %v", readErr)
	}
	if string(got) != "old-binary" {
		t.Fatalf("expected destination to remain unchanged, got %q", string(got))
	}
}
