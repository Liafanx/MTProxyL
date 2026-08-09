package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Backup is one entry of `mtproxyl backup list --json`.
type Backup struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"`
}

// backupNameRe matches exactly what create_backup produces:
// mtproxyl-YYYYMMDD-HHMMSS.tar.gz. The name goes into a sudo-invoked command,
// so it is validated, not cleaned: anchoring rejects separators, ".." and
// shell metacharacters outright.
var backupNameRe = regexp.MustCompile(`^mtproxyl-\d{8}-\d{6}\.tar\.gz$`)

// ErrInvalidBackupName marks a rejected archive name, so handlers can answer
// 400 rather than reporting it as a CLI failure.
var ErrInvalidBackupName = errors.New("invalid backup name")

// ErrBackupNotFound lets handlers answer 404 for a missing archive.
var ErrBackupNotFound = errors.New("backup not found")

// ValidateBackupName reports whether name is a well-formed backup archive name.
func ValidateBackupName(name string) error {
	if !backupNameRe.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalidBackupName, name)
	}
	return nil
}

// ListBackups returns the available backup archives, newest first.
func (c *Client) ListBackups(ctx context.Context) ([]Backup, error) {
	out, err := c.run(ctx, "backup", "list", "--json")
	if err != nil {
		return nil, err
	}
	var list []Backup
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &list); err != nil {
		return nil, fmt.Errorf("parse backup list: %w", err)
	}
	if list == nil {
		list = []Backup{}
	}
	return list, nil
}

// CreateBackup archives MTProxyL's settings and returns the new archive's name.
func (c *Client) CreateBackup(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "backup")
	if err != nil {
		return "", err
	}
	// create_backup logs a human-readable line first and echoes the bare path
	// last, so the final non-empty line is the path.
	path := lastMeaningfulLine(out)
	name := filepath.Base(strings.TrimSpace(path))
	if err := ValidateBackupName(name); err != nil {
		return "", fmt.Errorf("unexpected backup output %q: %w", path, err)
	}
	return name, nil
}

// RestoreBackup restores an archive by name. Only a name, never a path: it is
// resolved against MTProxyL's own backup directory.
func (c *Client) RestoreBackup(ctx context.Context, name string) (string, error) {
	if err := ValidateBackupName(name); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "restore", filepath.Join(c.cfg.BackupDir(), name))
	return stripANSI(out), err
}

// ResolveBackupPath validates name and returns its absolute path, for handlers
// that serve the archive for download.
func (c *Client) ResolveBackupPath(name string) (string, error) {
	if err := ValidateBackupName(name); err != nil {
		return "", err
	}
	return filepath.Join(c.cfg.BackupDir(), name), nil
}

// ReadBackup returns an archive's bytes through the privileged CLI: backups are
// root-owned 600, so the panel cannot open them directly.
// Output is raw — the ANSI stripper would corrupt gzip.
func (c *Client) ReadBackup(ctx context.Context, name string) ([]byte, error) {
	if err := ValidateBackupName(name); err != nil {
		return nil, err
	}
	out, err := c.run(ctx, "backup", "cat", name)
	if err != nil {
		// MTProxyL различает «нет такого файла» кодом 3, чтобы панель могла
		// ответить 404, а не «шлюз не смог» на обычное отсутствие бэкапа.
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 3 {
			return nil, fmt.Errorf("%w: %s", ErrBackupNotFound, name)
		}
		return nil, err
	}
	return []byte(out), nil
}
