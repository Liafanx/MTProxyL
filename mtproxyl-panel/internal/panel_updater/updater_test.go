package panel_updater

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/github"
	"github.com/Liafanx/mtproxyl-panel/internal/sysutil"
)

func TestNewLoadsLegacyStatusFileWhenDataDirConfigured(t *testing.T) {
	oldStagingDir := stagingDir
	oldDetectedVariant := detectedVariant
	t.Cleanup(func() {
		stagingDir = oldStagingDir
		detectedVariant = oldDetectedVariant
	})

	legacyPath := filepath.Join(os.TempDir(), "mtproxyl-panel-update-status.json")
	restoreLegacy := preserveFileForTest(t, legacyPath)
	t.Cleanup(restoreLegacy)

	status := Status{
		Phase:   PhaseDone,
		Message: "updated to 1.2.3",
		Log:     []string{"done"},
	}
	writeJSONFile(t, legacyPath, status)

	dataDir := t.TempDir()
	upd := New("1.0.0", "/opt/bin/mtproxyl-panel", "mtproxyl-panel", "owner/repo", dataDir, 1, 1, "")

	got := upd.GetStatus()
	if got.Phase != PhaseDone {
		t.Fatalf("expected recovered phase %q, got %q", PhaseDone, got.Phase)
	}
	if got.Message != status.Message {
		t.Fatalf("expected recovered message %q, got %q", status.Message, got.Message)
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("expected legacy status file to be removed, stat err=%v", err)
	}
}

func TestNewCleansRecoveredStagedBackup(t *testing.T) {
	oldStagingDir := stagingDir
	oldDetectedVariant := detectedVariant
	t.Cleanup(func() {
		stagingDir = oldStagingDir
		detectedVariant = oldDetectedVariant
	})

	dataDir := t.TempDir()
	stageDir, err := sysutil.EnsureStagingDir(dataDir)
	if err != nil {
		t.Fatalf("EnsureStagingDir: %v", err)
	}

	statusPath := filepath.Join(dataDir, "panel-update-status.json")
	writeJSONFile(t, statusPath, Status{
		Phase:   PhaseDone,
		Message: "updated to 2.0.0",
	})

	binaryPath := filepath.Join(t.TempDir(), "mtproxyl-panel")
	backupPath := filepath.Join(stageDir, filepath.Base(binaryPath)+".bak")
	if err := os.WriteFile(backupPath, []byte("backup"), 0o644); err != nil {
		t.Fatalf("write backup: %v", err)
	}

	upd := New("1.0.0", binaryPath, "mtproxyl-panel", "owner/repo", dataDir, 1, 1, "")
	if got := upd.GetStatus(); got.Phase != PhaseDone {
		t.Fatalf("expected recovered phase %q, got %q", PhaseDone, got.Phase)
	}
	if _, err := os.Stat(backupPath); !os.IsNotExist(err) {
		t.Fatalf("expected recovered backup to be removed, stat err=%v", err)
	}
}

// The panel binary is built static (CGO_ENABLED=0), so the libc token in the
// asset name is cosmetic and releases only ship the "gnu" variant. The matcher
// must still resolve the asset even when variant detection falls back to "musl"
// (older glibc, Alpine, missing ldd) — otherwise every release is filtered out
// and the UI shows "no available versions".
func TestAssetMatcherFallsBackToPublishedVariant(t *testing.T) {
	old := detectedVariant
	t.Cleanup(func() { detectedVariant = old })
	detectedVariant = "musl" // broken case: detection resolves to a variant that isn't published

	binName := "mtproxyl-panel-" + archString() + "-linux-gnu.tar.gz"
	sumName := "mtproxyl-panel-" + archString() + "-linux-gnu.sha256"
	assets := []github.GitHubAsset{
		{Name: sumName},
		{Name: binName},
	}

	bin, sum := NewAssetMatcher()(assets)
	if bin == nil || bin.Name != binName {
		t.Fatalf("expected binary %q, got %v", binName, bin)
	}
	if sum == nil || sum.Name != sumName {
		t.Fatalf("expected checksum %q, got %v", sumName, sum)
	}
}

// When the exact detected variant IS published, it must be preferred over other variants.
func TestAssetMatcherPrefersExactVariant(t *testing.T) {
	old := detectedVariant
	t.Cleanup(func() { detectedVariant = old })
	detectedVariant = "gnu"

	gnuName := "mtproxyl-panel-" + archString() + "-linux-gnu.tar.gz"
	muslName := "mtproxyl-panel-" + archString() + "-linux-musl.tar.gz"
	assets := []github.GitHubAsset{
		{Name: muslName},
		{Name: gnuName},
	}

	bin, _ := NewAssetMatcher()(assets)
	if bin == nil || bin.Name != gnuName {
		t.Fatalf("expected preferred binary %q, got %v", gnuName, bin)
	}
}

func writeJSONFile(t *testing.T, path string, value any) {
	t.Helper()

	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func preserveFileForTest(t *testing.T, path string) func() {
	t.Helper()

	original, err := os.ReadFile(path)
	if err == nil {
		return func() {
			if writeErr := os.WriteFile(path, original, 0o644); writeErr != nil {
				t.Fatalf("restore %s: %v", path, writeErr)
			}
		}
	}
	if !os.IsNotExist(err) {
		t.Fatalf("read %s: %v", path, err)
	}
	if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
		t.Fatalf("remove %s: %v", path, removeErr)
	}
	return func() {
		if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
			t.Fatalf("cleanup %s: %v", path, removeErr)
		}
	}
}
