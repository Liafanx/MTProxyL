package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
)

const (
	defaultPanelName       = "MTProxyL-Panel"
	defaultLoginTitle      = "MTProxyL-Panel"
	defaultLoginSubtitle   = "Управление MTProxy"
	brandingFileName       = "branding.json"
	brandingBackgroundName = "login-background"
	panelBackgroundName    = "panel-background"
	maxBrandingImageSize   = 8 << 20 // 8 MiB
	panelBackgroundNone    = "none"
	panelBackgroundLogin   = "login"
	panelBackgroundCustom  = "custom"
)

// Branding contains only presentation settings. It deliberately lives outside
// config.toml: the panel process can persist it without root and upgrades do
// not rewrite it.
type Branding struct {
	PanelName               string `json:"panel_name"`
	HasIcon                 bool   `json:"has_icon"`
	IconRevision            string `json:"icon_revision,omitempty"`
	LoginTitle              string `json:"login_title"`
	LoginSubtitle           string `json:"login_subtitle"`
	HasBackground           bool   `json:"has_background"`
	BackgroundRevision      string `json:"background_revision,omitempty"`
	PanelBackgroundMode     string `json:"panel_background_mode"`
	HasPanelBackground      bool   `json:"has_panel_background"`
	PanelBackgroundRevision string `json:"panel_background_revision,omitempty"`
}

type brandingFile struct {
	PanelName           string `json:"panel_name"`
	LoginTitle          string `json:"login_title"`
	LoginSubtitle       string `json:"login_subtitle"`
	PanelBackgroundMode string `json:"panel_background_mode"`
}

type brandingStore struct {
	mu                  sync.RWMutex
	settingsPath        string
	backgroundPath      string
	panelBackgroundPath string
	iconPath            string
	settings            brandingFile
}

func defaultBrandingFile() brandingFile {
	return brandingFile{
		PanelName:           defaultPanelName,
		LoginTitle:          defaultLoginTitle,
		LoginSubtitle:       defaultLoginSubtitle,
		PanelBackgroundMode: panelBackgroundNone,
	}
}

func newBrandingStore(dataDir string) (*brandingStore, error) {
	if dataDir == "" {
		return nil, errors.New("data_dir is empty")
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create branding data directory: %w", err)
	}

	s := &brandingStore{
		settingsPath:        filepath.Join(dataDir, brandingFileName),
		backgroundPath:      filepath.Join(dataDir, brandingBackgroundName),
		panelBackgroundPath: filepath.Join(dataDir, panelBackgroundName),
		iconPath:            filepath.Join(dataDir, "panel-icon"),
		settings:            defaultBrandingFile(),
	}
	raw, err := os.ReadFile(s.settingsPath)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read branding settings: %w", err)
	}

	var saved brandingFile
	if err := json.Unmarshal(raw, &saved); err != nil {
		return nil, fmt.Errorf("parse branding settings: %w", err)
	}
	saved = normalizeBrandingFile(saved)
	if err := validateBrandingFile(saved); err != nil {
		return nil, fmt.Errorf("validate branding settings: %w", err)
	}
	s.settings = saved
	return s, nil
}

func (s *brandingStore) get() Branding {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.getLocked()
}

func (s *brandingStore) getLocked() Branding {
	settings := s.settings
	result := Branding{
		PanelName:           settings.PanelName,
		LoginTitle:          settings.LoginTitle,
		LoginSubtitle:       settings.LoginSubtitle,
		PanelBackgroundMode: settings.PanelBackgroundMode,
	}
	if info, err := os.Stat(s.backgroundPath); err == nil && info.Mode().IsRegular() {
		result.HasBackground = true
		result.BackgroundRevision = strconv.FormatInt(info.ModTime().UnixNano(), 10)
	}
	if info, err := os.Stat(s.panelBackgroundPath); err == nil && info.Mode().IsRegular() {
		result.HasPanelBackground = true
		result.PanelBackgroundRevision = strconv.FormatInt(info.ModTime().UnixNano(), 10)
	}
	if info, err := os.Stat(s.iconPath); err == nil && info.Mode().IsRegular() {
		result.HasIcon = true
		result.IconRevision = strconv.FormatInt(info.ModTime().UnixNano(), 10)
	}
	return result
}

func (s *brandingStore) update(next brandingFile) (Branding, error) {
	next = normalizeBrandingFile(next)
	if err := validateBrandingFile(next); err != nil {
		return Branding{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if err := writeJSONAtomic(s.settingsPath, next); err != nil {
		return Branding{}, err
	}
	s.settings = next

	return s.getLocked(), nil
}

func normalizeBrandingFile(v brandingFile) brandingFile {
	v.PanelName = strings.TrimSpace(v.PanelName)
	v.LoginTitle = strings.TrimSpace(v.LoginTitle)
	v.LoginSubtitle = strings.TrimSpace(v.LoginSubtitle)
	v.PanelBackgroundMode = strings.TrimSpace(v.PanelBackgroundMode)
	if v.PanelBackgroundMode == "" {
		v.PanelBackgroundMode = panelBackgroundNone
	}
	return v
}

func validateBrandingFile(v brandingFile) error {
	if err := validateBrandingText("Название панели", v.PanelName, 1, 80); err != nil {
		return err
	}
	if err := validateBrandingText("Заголовок страницы входа", v.LoginTitle, 1, 80); err != nil {
		return err
	}
	if err := validateBrandingText("Подзаголовок страницы входа", v.LoginSubtitle, 0, 160); err != nil {
		return err
	}
	switch v.PanelBackgroundMode {
	case panelBackgroundNone, panelBackgroundLogin, panelBackgroundCustom:
		return nil
	default:
		return errors.New("Фон панели: неизвестный режим")
	}
}

func validateBrandingText(name, value string, minRunes, maxRunes int) error {
	n := utf8.RuneCountInString(value)
	if n < minRunes || n > maxRunes {
		if minRunes == 0 {
			return fmt.Errorf("%s: максимум %d символов", name, maxRunes)
		}
		return fmt.Errorf("%s: от %d до %d символов", name, minRunes, maxRunes)
	}
	if strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return fmt.Errorf("%s: управляющие символы запрещены", name)
	}
	return nil
}

func writeJSONAtomic(path string, value any) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".branding-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary settings file: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("protect temporary settings file: %w", err)
	}
	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(value); err != nil {
		tmp.Close()
		return fmt.Errorf("encode branding settings: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("sync branding settings: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close branding settings: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("replace branding settings: %w", err)
	}
	return nil
}

func detectBrandingImage(data []byte) (string, error) {
	mime := http.DetectContentType(data)
	switch mime {
	case "image/jpeg", "image/png", "image/webp":
		return mime, nil
	default:
		return "", fmt.Errorf("поддерживаются только PNG, JPEG и WebP")
	}
}

func (s *brandingStore) putBackground(data []byte) (Branding, error) {
	return s.putImage(s.backgroundPath, data)
}

func (s *brandingStore) putPanelBackground(data []byte) (Branding, error) {
	return s.putImage(s.panelBackgroundPath, data)
}

func (s *brandingStore) putImage(path string, data []byte) (Branding, error) {
	if len(data) == 0 {
		return Branding{}, errors.New("файл изображения пуст")
	}
	if _, err := detectPanelImage(data, path == s.iconPath); err != nil {
		return Branding{}, err
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), ".panel-image-*.tmp")
	if err != nil {
		return Branding{}, fmt.Errorf("create temporary image: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return Branding{}, fmt.Errorf("protect temporary image: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return Branding{}, fmt.Errorf("write background image: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return Branding{}, fmt.Errorf("sync background image: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return Branding{}, fmt.Errorf("close background image: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Rename(tmpPath, path); err != nil {
		return Branding{}, fmt.Errorf("replace background image: %w", err)
	}
	return s.getLocked(), nil
}

func (s *brandingStore) deleteBackground() (Branding, error) {
	return s.deleteImage(s.backgroundPath)
}

func (s *brandingStore) deletePanelBackground() (Branding, error) {
	return s.deleteImage(s.panelBackgroundPath)
}

func (s *brandingStore) deleteImage(path string) (Branding, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return Branding{}, fmt.Errorf("delete background image: %w", err)
	}
	return s.getLocked(), nil
}

func (s *brandingStore) serveBackground(w http.ResponseWriter, r *http.Request) {
	s.serveImage(w, r, s.backgroundPath, brandingBackgroundName)
}

func (s *brandingStore) servePanelBackground(w http.ResponseWriter, r *http.Request) {
	s.serveImage(w, r, s.panelBackgroundPath, panelBackgroundName)
}

func (s *brandingStore) serveImage(w http.ResponseWriter, r *http.Request, path, name string) {
	s.mu.RLock()
	data, err := os.ReadFile(path)
	if err != nil {
		s.mu.RUnlock()
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		writeError(w, http.StatusInternalServerError, "background_read_failed", "Не удалось прочитать фон")
		return
	}
	info, statErr := os.Stat(path)
	s.mu.RUnlock()
	if statErr != nil {
		writeError(w, http.StatusInternalServerError, "background_read_failed", "Не удалось прочитать фон")
		return
	}
	mime, err := detectPanelImage(data, path == s.iconPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "background_invalid", "Сохранённый фон повреждён")
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "public, max-age=300")
	http.ServeContent(w, r, name, info.ModTime(), bytes.NewReader(data))
}

func detectPanelImage(data []byte, icon bool) (string, error) {
	if !icon {
		return detectBrandingImage(data)
	}
	mime := http.DetectContentType(data)
	if mime == "image/png" || mime == "image/x-icon" || mime == "image/vnd.microsoft.icon" {
		return mime, nil
	}
	return "", errors.New("для иконки поддерживаются только ICO и PNG")
}

func readBrandingImage(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBrandingImageSize+1)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "image_too_large", "Изображение больше 8 МБ")
			return nil, false
		}
		writeError(w, http.StatusBadRequest, "image_read_failed", "Не удалось прочитать изображение")
		return nil, false
	}
	if len(data) > maxBrandingImageSize {
		writeError(w, http.StatusRequestEntityTooLarge, "image_too_large", "Изображение больше 8 МБ")
		return nil, false
	}
	if len(data) == 0 {
		writeError(w, http.StatusBadRequest, "invalid_image", "Файл изображения пуст")
		return nil, false
	}
	if _, err := detectPanelImage(data, strings.HasSuffix(r.URL.Path, "/icon")); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_image", err.Error())
		return nil, false
	}
	return data, true
}

func brandingImageUploadHandler(
	save func([]byte) (Branding, error), logName, errorMessage string,
) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data, ok := readBrandingImage(w, r)
		if !ok {
			return
		}
		result, err := save(data)
		if err != nil {
			log.Printf("%s save: %v", logName, err)
			writeError(w, http.StatusInternalServerError, "background_save_failed", errorMessage)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	}
}

func brandingImageDeleteHandler(
	remove func() (Branding, error), logName, errorMessage string,
) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		result, err := remove()
		if err != nil {
			log.Printf("%s delete: %v", logName, err)
			writeError(w, http.StatusInternalServerError, "background_delete_failed", errorMessage)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	}
}

func (s *Server) registerBrandingRoutes(mux *http.ServeMux, jwtSecret []byte, store *brandingStore) {
	mux.HandleFunc("GET /api/branding", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: store.get()})
	})
	mux.HandleFunc("GET /api/branding/background", store.serveBackground)
	mux.HandleFunc("GET /api/branding/icon", func(w http.ResponseWriter, r *http.Request) {
		store.serveImage(w, r, store.iconPath, "favicon.ico")
	})

	protected := func(h http.HandlerFunc) http.Handler { return auth.RequireAuth(jwtSecret, h) }
	mux.Handle("PUT /api/panel/settings/icon", protected(brandingImageUploadHandler(
		func(data []byte) (Branding, error) { return store.putImage(store.iconPath, data) },
		"panel icon", "Не удалось сохранить иконку",
	)))
	mux.Handle("DELETE /api/panel/settings/icon", protected(brandingImageDeleteHandler(
		func() (Branding, error) { return store.deleteImage(store.iconPath) },
		"panel icon", "Не удалось удалить иконку",
	)))
	mux.Handle("GET /api/branding/panel-background", protected(store.servePanelBackground))
	mux.Handle("PUT /api/panel/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		var req brandingFile
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}
		req = normalizeBrandingFile(req)
		if err := validateBrandingFile(req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_branding", err.Error())
			return
		}
		result, err := store.update(req)
		if err != nil {
			log.Printf("branding settings save: %v", err)
			writeError(w, http.StatusInternalServerError, "branding_save_failed", "Не удалось сохранить настройки панели")
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	}))

	mux.Handle("PUT /api/panel/settings/background", protected(brandingImageUploadHandler(
		store.putBackground, "branding background", "Не удалось сохранить фон страницы входа",
	)))
	mux.Handle("DELETE /api/panel/settings/background", protected(brandingImageDeleteHandler(
		store.deleteBackground, "branding background", "Не удалось удалить фон страницы входа",
	)))
	mux.Handle("PUT /api/panel/settings/panel-background", protected(brandingImageUploadHandler(
		store.putPanelBackground, "panel background", "Не удалось сохранить фон панели",
	)))
	mux.Handle("DELETE /api/panel/settings/panel-background", protected(brandingImageDeleteHandler(
		store.deletePanelBackground, "panel background", "Не удалось удалить фон панели",
	)))
}
