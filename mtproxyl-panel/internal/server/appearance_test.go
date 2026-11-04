package server

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func appearanceStores(t *testing.T) (*brandingStore, *themeStore) {
	t.Helper()
	dir := t.TempDir()
	b, err := newBrandingStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	s, err := newThemeStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	return b, s
}

func TestAppearanceRoundTripAndAuth(t *testing.T) {
	b, s := appearanceStores(t)
	brand := defaultBrandingFile()
	brand.PanelName = "Своя панель"
	brand.PanelBackgroundMode = panelBackgroundLogin
	if _, err := b.update(brand); err != nil {
		t.Fatal(err)
	}
	if _, err := s.update(themeSaveRequest{Theme: "custom", Colors: map[string]string{"bg": "#123456"}}); err != nil {
		t.Fatal(err)
	}
	image := append([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}, make([]byte, 16)...)
	if _, err := b.putBackground(image); err != nil {
		t.Fatal(err)
	}
	icon := append([]byte{0, 0, 1, 0}, make([]byte, 32)...)
	if _, err := b.putImage(b.iconPath, icon); err != nil {
		t.Fatal(err)
	}
	archive, err := exportAppearance(b, s)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(archive, []byte("config.toml")) {
		t.Fatal("configuration leaked")
	}
	b2, s2 := appearanceStores(t)
	if _, err := b2.putPanelBackground(image); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	New(nil).registerAppearanceRoutes(mux, testJWTSecret, b2, s2)
	for _, method := range []string{"GET", "POST"} {
		r := httptest.NewRecorder()
		mux.ServeHTTP(r, httptest.NewRequest(method, "/api/panel/settings/appearance", nil))
		if r.Code != 401 {
			t.Fatalf("unauthorized %s: %d", method, r.Code)
		}
	}
	req := authedRequest(t, "POST", "/api/panel/settings/appearance", "")
	req.Body = io.NopCloser(bytes.NewReader(archive))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("import: %d %s", rec.Code, rec.Body.String())
	}
	if b2.get().PanelName != brand.PanelName || s2.get().Colors["bg"] != "#123456" || !b2.get().HasIcon || b2.get().HasPanelBackground {
		t.Fatal("round trip mismatch")
	}
	reloaded, err := newThemeStore(filepath.Dir(s2.path))
	if err != nil || reloaded.get().Theme != "custom" {
		t.Fatal("theme not persisted")
	}
	for _, name := range []string{themeFileName, brandingFileName, brandingBackgroundName, "panel-icon"} {
		info, err := os.Stat(filepath.Join(filepath.Dir(s2.path), name))
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("permissions: %s %v", name, err)
		}
	}
	out := httptest.NewRecorder()
	mux.ServeHTTP(out, authedRequest(t, "GET", "/api/panel/settings/appearance", ""))
	if out.Code != 200 || out.Header().Get("Content-Type") != "application/zip" {
		t.Fatal("export route")
	}
}

func TestAppearanceRejectsBeforeWriting(t *testing.T) {
	b, s := appearanceStores(t)
	manifest, _ := json.Marshal(appearanceManifest{Format: "mtproxyl-panel-appearance", Version: 1, Theme: themeSaveRequest{Theme: "dark"}, Branding: defaultBrandingFile()})
	for _, names := range [][]string{{"../theme.json"}, {"config.toml"}, {"appearance.json", "appearance.json"}, {"panel-icon"}} {
		var buf bytes.Buffer
		w := zip.NewWriter(&buf)
		f, _ := w.Create("appearance.json")
		f.Write(manifest)
		for _, name := range names {
			f, _ := w.Create(name)
			f.Write([]byte("bad"))
		}
		w.Close()
		if err := importAppearance(buf.Bytes(), b, s); err == nil {
			t.Fatalf("accepted %v", names)
		}
		if s.get().Configured {
			t.Fatal("invalid import changed settings")
		}
		if _, err := os.Stat(s.path); !os.IsNotExist(err) {
			t.Fatal("invalid import wrote file")
		}
	}
	if err := importAppearance([]byte("invalid zip"), b, s); err == nil {
		t.Fatal("accepted invalid zip")
	}
}
