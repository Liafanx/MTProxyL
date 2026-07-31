package config

import (
	"os"
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
