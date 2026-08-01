package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

var testJWTSecret = []byte("test-secret-for-mtproxyl-routes")

// newMtproxylMux builds a mux with only the MTProxyL routes registered.
func newMtproxylMux(t *testing.T, cfg config.MtproxylConfig) *http.ServeMux {
	t.Helper()
	s := New(&config.Config{Mtproxyl: cfg})
	mux := http.NewServeMux()
	s.registerMtproxylRoutes(mux, testJWTSecret)
	return mux
}

// authedRequest returns a request carrying a valid session cookie.
func authedRequest(t *testing.T, method, target string, body string) *http.Request {
	t.Helper()
	token, err := auth.GenerateToken("admin", testJWTSecret, time.Hour)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, target, nil)
	} else {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	}
	r.AddCookie(&http.Cookie{Name: "session", Value: token})
	return r
}

func TestMtproxylRoutesRequireAuth(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})

	for _, target := range []string{
		"/api/mtproxyl/status",
		"/api/mtproxyl/mode",
		"/api/mtproxyl/selfmask",
		"/api/mtproxyl/backups",
		"/api/mtproxyl/backups/mtproxyl-20260101-101010.tar.gz/download",
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, target, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without auth: got %d, want 401", target, rec.Code)
		}
	}
}

func TestDisabledBridgeReportsUnavailable(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: false})

	// The availability probe still answers, so the UI can hide the features.
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/mtproxyl/status", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", rec.Code)
	}
	var resp struct {
		Data struct {
			Enabled bool `json:"enabled"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Data.Enabled {
		t.Error("enabled = true, want false")
	}

	// Feature routes refuse rather than shelling out.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/mtproxyl/mode", ""))
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("mode with bridge off: got %d, want 503", rec.Code)
	}
}

func TestDownloadRejectsBadNames(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})

	// Path-escaping names must be refused before any file is opened. They are
	// URL-escaped so they survive as a single path segment to the handler.
	for _, name := range []string{
		"..%2f..%2fetc%2fshadow",
		"%2fetc%2fpasswd",
		"settings.conf",
		"pre-migrate-1700000000.tar.gz",
		"mtproxyl-20260101-101010.tar.gz%20;%20id",
	} {
		target := "/api/mtproxyl/backups/" + name + "/download"
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, target, ""))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("download %q: got %d, want 400", name, rec.Code)
		}
	}
}

func TestDownloadServesValidBackup(t *testing.T) {
	dir := t.TempDir()
	cfg := config.MtproxylConfig{Enabled: true, InstallDir: dir}
	mustWriteBackup(t, cfg.BackupDir(), "mtproxyl-20260101-101010.tar.gz", "payload")

	mux := newMtproxylMux(t, cfg)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet,
		"/api/mtproxyl/backups/mtproxyl-20260101-101010.tar.gz/download", ""))

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != "payload" {
		t.Errorf("body = %q, want %q", got, "payload")
	}
	if cd := rec.Header().Get("Content-Disposition"); !strings.Contains(cd, "mtproxyl-20260101-101010.tar.gz") {
		t.Errorf("Content-Disposition = %q", cd)
	}
}

func TestDownloadMissingBackupIs404(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet,
		"/api/mtproxyl/backups/mtproxyl-20991231-235959.tar.gz/download", ""))
	if rec.Code != http.StatusNotFound {
		t.Errorf("got %d, want 404", rec.Code)
	}
}

func TestSwitchModeRejectsInvalidMode(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})

	for _, body := range []string{`{"mode":"root"}`, `{"mode":""}`, `{"mode":"MANAGER"}`} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/mode", body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("mode %s: got %d, want 400", body, rec.Code)
		}
	}

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/mode", `not json`))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("malformed body: got %d, want 400", rec.Code)
	}
}

func TestRestoreRejectsBadNameBeforeStarting(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})

	for _, body := range []string{
		`{"name":"../../etc/shadow"}`,
		`{"name":"settings.conf"}`,
		`{"name":""}`,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/backups/restore", body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("restore %s: got %d, want 400", body, rec.Code)
		}
	}
}

func TestEscapedTraversalCannotEscapeBackupDir(t *testing.T) {
	// Belt-and-braces: even a name that survives URL decoding as a traversal
	// must not resolve outside the backup directory.
	dir := t.TempDir()
	cfg := config.MtproxylConfig{Enabled: true, InstallDir: dir}
	mux := newMtproxylMux(t, cfg)

	target := "/api/mtproxyl/backups/" + url.PathEscape("../../../etc/passwd") + "/download"
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, target, ""))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

// mustWriteBackup creates a backup file with the given contents.
func mustWriteBackup(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
		t.Fatalf("write backup: %v", err)
	}
}

func TestPhase2RoutesRequireAuth(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})
	for _, target := range []string{
		"/api/mtproxyl/nft",
		"/api/mtproxyl/geoblock",
		"/api/mtproxyl/upstreams",
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, target, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without auth: got %d, want 401", target, rec.Code)
		}
	}
}

func TestNftParamRejectsInjectionOverHTTP(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})
	for _, body := range []string{
		`{"key":"NFT_IOS_RATE","value":"1/second; id"}`,
		`{"key":"NFT_IOS_RATE; id","value":"1/second"}`,
		`{"key":"NFT_IOS_RATE","value":"--flag"}`,
		`{"key":"","value":"x"}`,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/nft/params", body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("params %s: got %d, want 400", body, rec.Code)
		}
	}
}

func TestNftActionRejectsUnlisted(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})
	for _, body := range []string{
		`{"action":"set"}`,
		`{"action":"apply; id"}`,
		`{"action":""}`,
		`{"action":"status"}`,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/nft/action", body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("action %s: got %d, want 400", body, rec.Code)
		}
	}
}

func TestGeoblockRejectsBadCountry(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/geoblock", `{"country":"us; id"}`))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("add: got %d, want 400", rec.Code)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodDelete,
		"/api/mtproxyl/geoblock/"+url.PathEscape("../../etc"), ""))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("delete: got %d, want 400", rec.Code)
	}
}

func TestUpstreamRejectsBadSpec(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})
	for _, body := range []string{
		`{"name":"a; id","type":"direct"}`,
		`{"name":"x","type":"http"}`,
		`{"name":"x","type":"socks5","address":"1.2.3.4:1080; id"}`,
		`{"name":"x","type":"socks5"}`,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/upstreams", body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("upstream %s: got %d, want 400", body, rec.Code)
		}
	}

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodDelete,
		"/api/mtproxyl/upstreams/"+url.PathEscape("../etc"), ""))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("delete: got %d, want 400", rec.Code)
	}
}

func TestSelfmaskParamRejectsInjection(t *testing.T) {
	mux := newMtproxylMux(t, config.MtproxylConfig{Enabled: true, InstallDir: t.TempDir()})
	for _, body := range []string{
		`{"key":"SELFMASK_DOMAIN","value":"a; id"}`,
		`{"key":"SELFMASK_DOMAIN; id","value":"a"}`,
		`{"key":"NFT_IOS_RATE","value":"1/second"}`,
		`{"key":"SELFMASK_DOMAIN","value":"--flag"}`,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/mtproxyl/selfmask/params", body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("params %s: got %d, want 400", body, rec.Code)
		}
	}
}
