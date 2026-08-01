package config

import (
	"os"
	"path/filepath"
	"testing"
)

// Конфиги, которые генерирует установщик, должны разбираться панелью — иначе
// служба не поднимется, а пользователь увидит только «Failed to start».
func TestInstallerTLSConfigsLoad(t *testing.T) {
	cases := []struct {
		name      string
		tls       string
		wantSelf  bool
		wantCert  string
		wantACME  string
		wantHosts int
	}{
		{
			name: "самоподписанный",
			tls: `
[tls]
self_signed = true
cert_file = "/var/lib/mtproxyl-panel/certs/panel.crt"
key_file = "/var/lib/mtproxyl-panel/certs/panel.key"
self_signed_hosts = ["203.0.113.10"]`,
			wantSelf:  true,
			wantCert:  "/var/lib/mtproxyl-panel/certs/panel.crt",
			wantHosts: 1,
		},
		{
			name: "lets encrypt",
			tls: `
[tls]
acme_domain = "panel.example.com"
acme_cache_dir = "/var/lib/mtproxyl-panel/certs"`,
			wantACME: "panel.example.com",
		},
		{
			name: "свой сертификат",
			tls: `
[tls]
cert_file = "/etc/ssl/p.crt"
key_file = "/etc/ssl/p.key"`,
			wantCert: "/etc/ssl/p.crt",
		},
		{name: "без tls", tls: ""},
	}

	base := `listen = "0.0.0.0:8080"
data_dir = "/var/lib/mtproxyl-panel"

[telemt]
url = "http://127.0.0.1:9091"
binary_path = "/usr/local/bin/telemt"
service_name = "telemt"

[auth]
username = "admin"
password_hash = "$2a$10$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ012"
jwt_secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
session_ttl = "24h"`

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "config.toml")
			if err := os.WriteFile(p, []byte(base+tc.tls+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			cfg, err := Load(p)
			if err != nil {
				t.Fatalf("конфиг не грузится: %s", err)
			}
			if cfg.TLS.SelfSigned != tc.wantSelf {
				t.Errorf("self_signed = %v, ожидалось %v", cfg.TLS.SelfSigned, tc.wantSelf)
			}
			if cfg.TLS.CertFile != tc.wantCert {
				t.Errorf("cert_file = %q, ожидалось %q", cfg.TLS.CertFile, tc.wantCert)
			}
			if cfg.TLS.AcmeDomain != tc.wantACME {
				t.Errorf("acme_domain = %q, ожидалось %q", cfg.TLS.AcmeDomain, tc.wantACME)
			}
			if len(cfg.TLS.SelfSignedHosts) != tc.wantHosts {
				t.Errorf("хостов %d, ожидалось %d", len(cfg.TLS.SelfSignedHosts), tc.wantHosts)
			}
		})
	}
}
