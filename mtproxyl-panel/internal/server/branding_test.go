package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newBrandingMux(t *testing.T) (*http.ServeMux, *brandingStore) {
	t.Helper()
	store, err := newBrandingStore(t.TempDir())
	if err != nil {
		t.Fatalf("newBrandingStore: %v", err)
	}
	mux := http.NewServeMux()
	New(nil).registerBrandingRoutes(mux, testJWTSecret, store)
	return mux, store
}

func decodeBrandingResponse(t *testing.T, rec *httptest.ResponseRecorder) Branding {
	t.Helper()
	var response struct {
		OK   bool     `json:"ok"`
		Data Branding `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v (body: %s)", err, rec.Body.String())
	}
	if !response.OK {
		t.Fatalf("response not ok: %s", rec.Body.String())
	}
	return response.Data
}

func TestBrandingDefaultsArePublic(t *testing.T) {
	mux, _ := newBrandingMux(t)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/branding", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	got := decodeBrandingResponse(t, rec)
	if got.PanelName != defaultPanelName || got.LoginTitle != defaultLoginTitle || got.LoginSubtitle != defaultLoginSubtitle {
		t.Errorf("unexpected defaults: %+v", got)
	}
	if got.HasBackground {
		t.Error("HasBackground = true without an image")
	}
	if got.PanelBackgroundMode != panelBackgroundNone || got.HasPanelBackground {
		t.Errorf("unexpected panel background defaults: %+v", got)
	}
}

func TestLegacyBrandingDefaultsToNoPanelBackground(t *testing.T) {
	dir := t.TempDir()
	legacy := `{"panel_name":"Legacy","login_title":"Login","login_subtitle":"Proxy"}`
	if err := os.WriteFile(filepath.Join(dir, brandingFileName), []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := newBrandingStore(dir)
	if err != nil {
		t.Fatalf("load legacy branding: %v", err)
	}
	got := store.get()
	if got.PanelBackgroundMode != panelBackgroundNone {
		t.Errorf("legacy panel background mode = %q, want %q", got.PanelBackgroundMode, panelBackgroundNone)
	}
}

func TestBrandingUpdateRequiresAuthAndPersists(t *testing.T) {
	dir := t.TempDir()
	store, err := newBrandingStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	New(nil).registerBrandingRoutes(mux, testJWTSecret, store)
	body := `{"panel_name":" My panel ","login_title":"Welcome","login_subtitle":"Private proxy","panel_background_mode":"login"}`

	unauthorized := httptest.NewRecorder()
	mux.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodPut, "/api/panel/settings", strings.NewReader(body)))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("without auth: got %d, want 401", unauthorized.Code)
	}

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/panel/settings", body))
	if rec.Code != http.StatusOK {
		t.Fatalf("update: got %d (body: %s)", rec.Code, rec.Body.String())
	}
	got := decodeBrandingResponse(t, rec)
	if got.PanelName != "My panel" || got.LoginTitle != "Welcome" || got.LoginSubtitle != "Private proxy" || got.PanelBackgroundMode != panelBackgroundLogin {
		t.Errorf("unexpected update: %+v", got)
	}

	reloaded, err := newBrandingStore(dir)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got := reloaded.get(); got.PanelName != "My panel" || got.LoginTitle != "Welcome" || got.PanelBackgroundMode != panelBackgroundLogin {
		t.Errorf("settings were not persisted: %+v", got)
	}
	info, err := os.Stat(filepath.Join(dir, brandingFileName))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("branding mode = %o, want 600", info.Mode().Perm())
	}
}

func TestBrandingRejectsInvalidText(t *testing.T) {
	mux, _ := newBrandingMux(t)
	body := `{"panel_name":"","login_title":"Welcome","login_subtitle":"Proxy"}`
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/panel/settings", body))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

func TestBrandingRejectsInvalidPanelBackgroundMode(t *testing.T) {
	mux, _ := newBrandingMux(t)
	body := `{"panel_name":"Panel","login_title":"Welcome","login_subtitle":"Proxy","panel_background_mode":"remote"}`
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/panel/settings", body))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

func TestBrandingBackgroundUploadServeAndDelete(t *testing.T) {
	mux, _ := newBrandingMux(t)
	// DetectContentType only needs the PNG signature for this storage endpoint:
	// the panel never decodes the image, the browser does.
	png := string([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 0})

	upload := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPut, "/api/panel/settings/background", png)
	req.Header.Set("Content-Type", "image/png")
	mux.ServeHTTP(upload, req)
	if upload.Code != http.StatusOK {
		t.Fatalf("upload: got %d (body: %s)", upload.Code, upload.Body.String())
	}
	if got := decodeBrandingResponse(t, upload); !got.HasBackground || got.BackgroundRevision == "" {
		t.Errorf("unexpected upload result: %+v", got)
	}

	served := httptest.NewRecorder()
	mux.ServeHTTP(served, httptest.NewRequest(http.MethodGet, "/api/branding/background", nil))
	if served.Code != http.StatusOK {
		t.Fatalf("serve: got %d", served.Code)
	}
	if got := served.Header().Get("Content-Type"); got != "image/png" {
		t.Errorf("Content-Type = %q, want image/png", got)
	}
	if served.Body.String() != png {
		t.Error("served image differs from upload")
	}

	deleted := httptest.NewRecorder()
	mux.ServeHTTP(deleted, authedRequest(t, http.MethodDelete, "/api/panel/settings/background", ""))
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete: got %d (body: %s)", deleted.Code, deleted.Body.String())
	}
	if got := decodeBrandingResponse(t, deleted); got.HasBackground {
		t.Error("HasBackground = true after delete")
	}
}

func TestBrandingBackgroundRejectsNonImage(t *testing.T) {
	mux, _ := newBrandingMux(t)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/panel/settings/background", "<svg></svg>"))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

func TestPanelBackgroundIsStoredSeparately(t *testing.T) {
	mux, _ := newBrandingMux(t)
	loginPNG := string([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 'l', 'o', 'g', 'i', 'n'})
	panelPNG := string([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 'p', 'a', 'n', 'e', 'l'})

	for path, body := range map[string]string{
		"/api/panel/settings/background":       loginPNG,
		"/api/panel/settings/panel-background": panelPNG,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, path, body))
		if rec.Code != http.StatusOK {
			t.Fatalf("upload %s: got %d (body: %s)", path, rec.Code, rec.Body.String())
		}
	}

	brandingRec := httptest.NewRecorder()
	mux.ServeHTTP(brandingRec, httptest.NewRequest(http.MethodGet, "/api/branding", nil))
	branding := decodeBrandingResponse(t, brandingRec)
	if !branding.HasBackground || !branding.HasPanelBackground || branding.PanelBackgroundRevision == "" {
		t.Fatalf("both background files were not reported: %+v", branding)
	}

	for path, want := range map[string]string{
		"/api/branding/background":       loginPNG,
		"/api/branding/panel-background": panelPNG,
	} {
		rec := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, path, nil)
		if path == "/api/branding/panel-background" {
			request = authedRequest(t, http.MethodGet, path, "")
		}
		mux.ServeHTTP(rec, request)
		if rec.Code != http.StatusOK || rec.Body.String() != want {
			t.Errorf("serve %s: code=%d body differs=%v", path, rec.Code, rec.Body.String() != want)
		}
	}
	unauthorized := httptest.NewRecorder()
	mux.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/branding/panel-background", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Errorf("panel background without auth: got %d, want 401", unauthorized.Code)
	}

	deleted := httptest.NewRecorder()
	mux.ServeHTTP(deleted, authedRequest(t, http.MethodDelete, "/api/panel/settings/panel-background", ""))
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete panel background: got %d (body: %s)", deleted.Code, deleted.Body.String())
	}
	got := decodeBrandingResponse(t, deleted)
	if got.HasPanelBackground || !got.HasBackground {
		t.Errorf("deleting panel background affected wrong file: %+v", got)
	}
}
