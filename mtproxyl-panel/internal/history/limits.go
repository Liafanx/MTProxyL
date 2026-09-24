package history

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Limits — пределы хранения истории, задаются из панели.
type Limits struct {
	TrafficMaxUsers           int `json:"traffic_max_users"`
	FingerprintsMaxRecords    int `json:"fingerprints_max_records"`
	FingerprintsRetentionDays int `json:"fingerprints_retention_days"`
}

func DefaultLimits() Limits {
	return Limits{FingerprintsMaxRecords: DefaultFingerprintMaxRecords, FingerprintsRetentionDays: DefaultFingerprintRetentionDays}
}

func (l Limits) Validate() error {
	if l.TrafficMaxUsers < 0 || l.TrafficMaxUsers > 100000 {
		return errors.New("traffic_max_users: допустимо 0..100000")
	}
	if l.FingerprintsMaxRecords < 0 || l.FingerprintsMaxRecords > 100000 {
		return errors.New("fingerprints_max_records: допустимо 0..100000")
	}
	if l.FingerprintsRetentionDays < 0 || l.FingerprintsRetentionDays > 3650 {
		return errors.New("fingerprints_retention_days: допустимо 0..3650")
	}
	return nil
}

// LoadLimits читает файл; отсутствие файла — значения по умолчанию.
func LoadLimits(path string) (Limits, error) {
	l := DefaultLimits()
	if path == "" {
		return l, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return l, err
	}
	if err := json.Unmarshal(data, &l); err != nil {
		return DefaultLimits(), fmt.Errorf("history limits %s: %w", path, err)
	}
	if err := l.Validate(); err != nil {
		return DefaultLimits(), fmt.Errorf("history limits %s: %w", path, err)
	}
	return l, nil
}

func SaveLimits(path string, l Limits) error {
	if path == "" {
		return nil
	}
	data, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// FileSize — размер файла на диске, 0 для отсутствующего.
func FileSize(path string) int64 {
	if path == "" {
		return 0
	}
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return st.Size()
}
