package telemt_config

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/pelletier/go-toml/v2"
)

// SaveConfigFile writes Telemt's config file directly (file edit mode). It
// preserves the file's inode/owner/mode by rewriting in place, and falls back
// to `sudo tee` when the unprivileged panel lacks write permission. Backups are
// stored in backupDir (the panel's own data dir) so this never needs write
// access to Telemt's config directory.
func SaveConfigFile(configPath, content, backupDir string) error {
	if strings.Contains(configPath, "..") {
		return fmt.Errorf("invalid config path")
	}

	var testMap map[string]interface{}
	if err := toml.Unmarshal([]byte(content), &testMap); err != nil {
		return fmt.Errorf("invalid TOML syntax: %w", err)
	}
	content = removeIntegerUnderscores(content)
	content = inlineTablesToSections(content)

	if err := backupToDir(configPath, backupDir); err != nil {
		return fmt.Errorf("create backup: %w", err)
	}

	err := writeConfigInPlace(configPath, content)
	if errors.Is(err, os.ErrPermission) {
		err = writeViaSudoTee(configPath, content)
	}
	if err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	now := time.Now()
	_ = os.Chtimes(configPath, now, now)
	return nil
}

func backupToDir(src, backupDir string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if err := os.MkdirAll(backupDir, 0o700); err != nil {
		return err
	}
	name := fmt.Sprintf("%s.backup.%s", filepath.Base(src), time.Now().Format("20060102-150405"))
	return os.WriteFile(filepath.Join(backupDir, name), data, 0o600)
}

// writeViaSudoTee pipes content to `sudo tee <path>` (stdout discarded). The
// matching NOPASSWD sudoers line is installed by install.sh for file mode.
func writeViaSudoTee(configPath, content string) error {
	cmd := exec.Command("sudo", "-n", "tee", configPath)
	cmd.Stdin = strings.NewReader(content)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sudo tee failed: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
