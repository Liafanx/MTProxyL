package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
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

// backupNameRe matches exactly the archive names create_backup produces:
// mtproxyl-YYYYMMDD-HHMMSS.tar.gz
//
// Restore passes a filename into a sudo-invoked command, so the name is
// validated against this pattern rather than merely cleaned. Anchoring the
// whole string rejects path separators, "..", flags and shell metacharacters
// outright instead of trying to enumerate what is dangerous.
var backupNameRe = regexp.MustCompile(`^mtproxyl-\d{8}-\d{6}\.tar\.gz$`)

// ValidateBackupName reports whether name is a well-formed backup archive name.
func ValidateBackupName(name string) error {
	if !backupNameRe.MatchString(name) {
		return fmt.Errorf("invalid backup name %q", name)
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

// RestoreBackup restores a previously created archive by name.
//
// Only a name is accepted, never a path: it is validated and then resolved
// against MTProxyL's own backup directory, so a caller cannot direct the
// privileged restore at an arbitrary file.
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
