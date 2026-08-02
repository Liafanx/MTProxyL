package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadWithoutUsersSection(t *testing.T) {
	toml := `
listen = "0.0.0.0:8080"
[telemt]
url = "http://127.0.0.1:9091"
auth_header = "test"
[auth]
username = "admin"
password_hash = "$2a$10$abcdefghijklmnopqrstuvwxABCDEFGHIJ"
jwt_secret = "test-secret-that-is-at-least-32-characters"
`
	f, err := os.CreateTemp("", "config-*.toml")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(f.Name())
	f.WriteString(toml)
	f.Close()

	cfg, err := Load(f.Name())
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	if cfg.Users.UserAdTag != "" {
		t.Errorf("UserAdTag = %q, want empty", cfg.Users.UserAdTag)
	}
	if cfg.Users.MaxTcpConns != 0 {
		t.Errorf("MaxTcpConns = %d, want 0", cfg.Users.MaxTcpConns)
	}
	if cfg.Users.DataQuotaBytes != 0 {
		t.Errorf("DataQuotaBytes = %d, want 0", cfg.Users.DataQuotaBytes)
	}
	if cfg.Users.MaxUniqueIps != 0 {
		t.Errorf("MaxUniqueIps = %d, want 0", cfg.Users.MaxUniqueIps)
	}
	if cfg.Users.Expiration != "" {
		t.Errorf("Expiration = %q, want empty", cfg.Users.Expiration)
	}
}

func TestLoadWithUsersSection(t *testing.T) {
	toml := `
listen = "0.0.0.0:8080"
[telemt]
url = "http://127.0.0.1:9091"
auth_header = "test"
[auth]
username = "admin"
password_hash = "$2a$10$abcdefghijklmnopqrstuvwxABCDEFGHIJ"
jwt_secret = "test-secret-that-is-at-least-32-characters"
[users]
ad_tag = "1234567890abcdef1234567890abcdef"
max_tcp_conns = 5
data_quota_bytes = 1073741824
max_unique_ips = 3
expiration = "2027-12-31T23:59:59Z"
`
	f, err := os.CreateTemp("", "config-*.toml")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(f.Name())
	f.WriteString(toml)
	f.Close()

	cfg, err := Load(f.Name())
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	if cfg.Users.UserAdTag != "1234567890abcdef1234567890abcdef" {
		t.Errorf("UserAdTag = %q, want configured value", cfg.Users.UserAdTag)
	}
	if cfg.Users.MaxTcpConns != 5 {
		t.Errorf("MaxTcpConns = %d, want 5", cfg.Users.MaxTcpConns)
	}
	if cfg.Users.DataQuotaBytes != 1073741824 {
		t.Errorf("DataQuotaBytes = %d, want 1073741824", cfg.Users.DataQuotaBytes)
	}
	if cfg.Users.MaxUniqueIps != 3 {
		t.Errorf("MaxUniqueIps = %d, want 3", cfg.Users.MaxUniqueIps)
	}
	if cfg.Users.Expiration != "2027-12-31T23:59:59Z" {
		t.Errorf("Expiration = %q, want configured value", cfg.Users.Expiration)
	}
}

func TestLoadInvalidExpiration(t *testing.T) {
	toml := `
listen = "0.0.0.0:8080"
[telemt]
url = "http://127.0.0.1:9091"
auth_header = "test"
[auth]
username = "admin"
password_hash = "$2a$10$abcdefghijklmnopqrstuvwxABCDEFGHIJ"
jwt_secret = "test-secret-that-is-at-least-32-characters"
[users]
expiration = "not-a-valid-rfc3339"
`
	f, err := os.CreateTemp("", "config-*.toml")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(f.Name())
	f.WriteString(toml)
	f.Close()

	_, err = Load(f.Name())
	if err == nil {
		t.Fatal("Expected error for invalid expiration, got nil")
	}
}

func TestGeoIPAutodetect(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "GeoLite2-City.mmdb")
	if err := os.WriteFile(db, []byte("stub"), 0o644); err != nil {
		t.Fatalf("write db: %v", err)
	}

	// data_dir содержит базу — путь должен подставиться сам.
	cfg := writeAndLoad(t, `
listen = "0.0.0.0:8080"
data_dir = "`+dir+`"
[telemt]
url = "http://127.0.0.1:9091"
auth_header = "test"
[auth]
username = "admin"
password_hash = "$2a$10$abcdefghijklmnopqrstuvwxABCDEFGHIJ"
jwt_secret = "test-secret-that-is-at-least-32-characters"
`)
	if cfg.GeoIP.DBPath != db {
		t.Errorf("db_path = %q, want %q", cfg.GeoIP.DBPath, db)
	}
	// ASN-базы в каталоге нет, а системных путей на тестовой машине быть не
	// должно; главное — что автоподбор не выдумывает несуществующий файл.
	if cfg.GeoIP.ASNDBPath != "" && !fileReadable(cfg.GeoIP.ASNDBPath) {
		t.Errorf("asn_db_path = %q, but the file cannot be read", cfg.GeoIP.ASNDBPath)
	}

	// Явно заданный путь автоподбор не трогает.
	explicit := filepath.Join(dir, "custom.mmdb")
	if err := os.WriteFile(explicit, []byte("stub"), 0o644); err != nil {
		t.Fatalf("write db: %v", err)
	}
	cfg = writeAndLoad(t, `
listen = "0.0.0.0:8080"
data_dir = "`+dir+`"
[telemt]
url = "http://127.0.0.1:9091"
auth_header = "test"
[geoip]
db_path = "`+explicit+`"
[auth]
username = "admin"
password_hash = "$2a$10$abcdefghijklmnopqrstuvwxABCDEFGHIJ"
jwt_secret = "test-secret-that-is-at-least-32-characters"
`)
	if cfg.GeoIP.DBPath != explicit {
		t.Errorf("explicit db_path overridden: got %q, want %q", cfg.GeoIP.DBPath, explicit)
	}
}

// Нечитаемый файл для панели равнозначен отсутствующему — она работает без
// root и просто не сможет его открыть.
func TestGeoIPAutodetectSkipsUnreadable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file, so the permission case cannot be exercised")
	}
	dir := t.TempDir()
	db := filepath.Join(dir, "GeoLite2-City.mmdb")
	if err := os.WriteFile(db, []byte("stub"), 0o000); err != nil {
		t.Fatalf("write db: %v", err)
	}
	if got := findFirstReadable([]string{db}); got != "" {
		t.Errorf("findFirstReadable returned %q for an unreadable file", got)
	}
}

func fileReadable(p string) bool {
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

func writeAndLoad(t *testing.T, toml string) *Config {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "config-*.toml")
	if err != nil {
		t.Fatalf("temp file: %v", err)
	}
	if _, err := f.WriteString(toml); err != nil {
		t.Fatalf("write config: %v", err)
	}
	f.Close()
	cfg, err := Load(f.Name())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return cfg
}
