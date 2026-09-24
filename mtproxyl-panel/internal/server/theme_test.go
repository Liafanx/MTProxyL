package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func newThemeMux(t *testing.T) (*http.ServeMux, *themeStore) {
	t.Helper()
	store, err := newThemeStore(t.TempDir())
	if err != nil {
		t.Fatalf("newThemeStore: %v", err)
	}
	mux := http.NewServeMux()
	New(nil).registerThemeRoutes(mux, testJWTSecret, store)
	return mux, store
}

func decodeThemeResponse(t *testing.T, rec *httptest.ResponseRecorder) themeSettings {
	t.Helper()
	var response struct {
		OK   bool          `json:"ok"`
		Data themeSettings `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil || !response.OK {
		t.Fatalf("invalid theme response: %v: %s", err, rec.Body.String())
	}
	return response.Data
}

func TestThemeRoutesPersistAcrossBrowsers(t *testing.T) {
	mux, store := newThemeMux(t)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/theme", nil))
	initial := decodeThemeResponse(t, rec)
	if initial.Theme != "dark" || initial.Configured {
		t.Fatalf("unexpected defaults: %+v", initial)
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("theme response must not be cached")
	}

	body := `{"theme":"custom","colors":{"bg":"#ABCDEF","text":"#123456"}}`
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPut, "/api/panel/settings/theme", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized update: %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/panel/settings/theme", body))
	if rec.Code != http.StatusOK {
		t.Fatalf("save theme: %d: %s", rec.Code, rec.Body.String())
	}
	saved := decodeThemeResponse(t, rec)
	if !saved.Configured || saved.Theme != "custom" || saved.Colors["bg"] != "#abcdef" {
		t.Fatalf("unexpected saved theme: %+v", saved)
	}
	info, err := os.Stat(filepath.Join(filepath.Dir(store.path), themeFileName))
	if err != nil {
		t.Fatalf("theme file: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("theme file permissions: %v", info.Mode().Perm())
	}

	reloaded, err := newThemeStore(filepath.Dir(store.path))
	if err != nil {
		t.Fatalf("reload theme: %v", err)
	}
	secondBrowser := httptest.NewRecorder()
	otherMux := http.NewServeMux()
	New(nil).registerThemeRoutes(otherMux, testJWTSecret, reloaded)
	otherMux.ServeHTTP(secondBrowser, httptest.NewRequest(http.MethodGet, "/api/theme", nil))
	got := decodeThemeResponse(t, secondBrowser)
	if got.Theme != "custom" || got.Colors["bg"] != "#abcdef" {
		t.Fatalf("theme not shared across requests: %+v", got)
	}
}

func TestThemeRejectsInvalidColorsWithoutChangingSavedTheme(t *testing.T) {
	mux, store := newThemeMux(t)
	cases := []string{
		`{"theme":"unknown","colors":{}}`,
		`{"theme":"custom","colors":{"bad-key":"#abcdef"}}`,
		`{"theme":"custom","colors":{"bg":"red"}}`,
		`{"theme":"dark","colors":{},"extra":true}`,
	}
	for _, body := range cases {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/panel/settings/theme", body))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("invalid body accepted: %s (%d)", body, rec.Code)
		}
	}
	if store.get().Configured {
		t.Fatal("invalid theme unexpectedly persisted")
	}
}
