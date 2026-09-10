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
	maxBrandingImageSize   = 8 << 20 // 8 MiB
)

// Branding contains only presentation settings. It deliberately lives outside
// config.toml: the panel process can persist it without root and upgrades do
// not rewrite it.
type Branding struct {
	PanelName          string `json:"panel_name"`
	LoginTitle         string `json:"login_title"`
	LoginSubtitle      string `json:"login_subtitle"`
	HasBackground      bool   `json:"has_background"`
	BackgroundRevision string `json:"background_revision,omitempty"`
}

type brandingFile struct {
	PanelName     string `json:"panel_name"`
	LoginTitle    string `json:"login_title"`
	LoginSubtitle string `json:"login_subtitle"`
}

type brandingStore struct {
	mu             sync.RWMutex
	settingsPath   string
	backgroundPath string
	settings       brandingFile
}

func defaultBrandingFile() brandingFile {
	return brandingFile{
		PanelName:     defaultPanelName,
		LoginTitle:    defaultLoginTitle,
		LoginSubtitle: defaultLoginSubtitle,
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
		settingsPath:   filepath.Join(dataDir, brandingFileName),
		backgroundPath: filepath.Join(dataDir, brandingBackgroundName),
		settings:       defaultBrandingFile(),
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
	if err := validateBrandingFile(saved); err != nil {
		return nil, fmt.Errorf("validate branding settings: %w", err)
	}
	s.settings = saved
	return s, nil
}

func (s *brandingStore) get() Branding {
	s.mu.RLock()
	settings := s.settings
	s.mu.RUnlock()

	result := Branding{
		PanelName:     settings.PanelName,
		LoginTitle:    settings.LoginTitle,
		LoginSubtitle: settings.LoginSubtitle,
	}
	if info, err := os.Stat(s.backgroundPath); err == nil && info.Mode().IsRegular() {
		result.HasBackground = true
		result.BackgroundRevision = strconv.FormatInt(info.ModTime().UnixNano(), 10)
	}
	return result
}

func (s *brandingStore) update(next brandingFile) (Branding, error) {
	next.PanelName = strings.TrimSpace(next.PanelName)
	next.LoginTitle = strings.TrimSpace(next.LoginTitle)
	next.LoginSubtitle = strings.TrimSpace(next.LoginSubtitle)
	if err := validateBrandingFile(next); err != nil {
		return Branding{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if err := writeJSONAtomic(s.settingsPath, next); err != nil {
		return Branding{}, err
	}
	s.settings = next

	result := Branding{
		PanelName:     next.PanelName,
		LoginTitle:    next.LoginTitle,
		LoginSubtitle: next.LoginSubtitle,
	}
	if info, err := os.Stat(s.backgroundPath); err == nil && info.Mode().IsRegular() {
		result.HasBackground = true
		result.BackgroundRevision = strconv.FormatInt(info.ModTime().UnixNano(), 10)
	}
	return result, nil
}

func validateBrandingFile(v brandingFile) error {
	if err := validateBrandingText("Название панели", v.PanelName, 1, 80); err != nil {
		return err
	}
	if err := validateBrandingText("Заголовок страницы входа", v.LoginTitle, 1, 80); err != nil {
		return err
	}
	return validateBrandingText("Подзаголовок страницы входа", v.LoginSubtitle, 0, 160)
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
	if len(data) == 0 {
		return Branding{}, errors.New("файл изображения пуст")
	}
	if _, err := detectBrandingImage(data); err != nil {
		return Branding{}, err
	}

	tmp, err := os.CreateTemp(filepath.Dir(s.backgroundPath), ".login-background-*.tmp")
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
	if err := os.Rename(tmpPath, s.backgroundPath); err != nil {
		return Branding{}, fmt.Errorf("replace background image: %w", err)
	}
	result := Branding{
		PanelName:     s.settings.PanelName,
		LoginTitle:    s.settings.LoginTitle,
		LoginSubtitle: s.settings.LoginSubtitle,
		HasBackground: true,
	}
	if info, err := os.Stat(s.backgroundPath); err == nil {
		result.BackgroundRevision = strconv.FormatInt(info.ModTime().UnixNano(), 10)
	}
	return result, nil
}

func (s *brandingStore) deleteBackground() (Branding, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(s.backgroundPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return Branding{}, fmt.Errorf("delete background image: %w", err)
	}
	return Branding{
		PanelName:     s.settings.PanelName,
		LoginTitle:    s.settings.LoginTitle,
		LoginSubtitle: s.settings.LoginSubtitle,
	}, nil
}

func (s *brandingStore) serveBackground(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	data, err := os.ReadFile(s.backgroundPath)
	if err != nil {
		s.mu.RUnlock()
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		writeError(w, http.StatusInternalServerError, "background_read_failed", "Не удалось прочитать фон")
		return
	}
	info, statErr := os.Stat(s.backgroundPath)
	s.mu.RUnlock()
	if statErr != nil {
		writeError(w, http.StatusInternalServerError, "background_read_failed", "Не удалось прочитать фон")
		return
	}
	mime, err := detectBrandingImage(data)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "background_invalid", "Сохранённый фон повреждён")
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "public, max-age=300")
	http.ServeContent(w, r, brandingBackgroundName, info.ModTime(), bytes.NewReader(data))
}

func (s *Server) registerBrandingRoutes(mux *http.ServeMux, jwtSecret []byte, store *brandingStore) {
	mux.HandleFunc("GET /api/branding", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: store.get()})
	})
	mux.HandleFunc("GET /api/branding/background", store.serveBackground)

	protected := func(h http.HandlerFunc) http.Handler { return auth.RequireAuth(jwtSecret, h) }
	mux.Handle("PUT /api/panel/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		var req brandingFile
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}
		req.PanelName = strings.TrimSpace(req.PanelName)
		req.LoginTitle = strings.TrimSpace(req.LoginTitle)
		req.LoginSubtitle = strings.TrimSpace(req.LoginSubtitle)
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

	mux.Handle("PUT /api/panel/settings/background", protected(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBrandingImageSize+1)
		data, err := io.ReadAll(r.Body)
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				writeError(w, http.StatusRequestEntityTooLarge, "image_too_large", "Изображение больше 8 МБ")
				return
			}
			writeError(w, http.StatusBadRequest, "image_read_failed", "Не удалось прочитать изображение")
			return
		}
		if len(data) > maxBrandingImageSize {
			writeError(w, http.StatusRequestEntityTooLarge, "image_too_large", "Изображение больше 8 МБ")
			return
		}
		if len(data) == 0 {
			writeError(w, http.StatusBadRequest, "invalid_image", "Файл изображения пуст")
			return
		}
		if _, err := detectBrandingImage(data); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_image", err.Error())
			return
		}
		result, err := store.putBackground(data)
		if err != nil {
			log.Printf("branding background save: %v", err)
			writeError(w, http.StatusInternalServerError, "background_save_failed", "Не удалось сохранить фон")
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	}))

	mux.Handle("DELETE /api/panel/settings/background", protected(func(w http.ResponseWriter, r *http.Request) {
		result, err := store.deleteBackground()
		if err != nil {
			log.Printf("branding background delete: %v", err)
			writeError(w, http.StatusInternalServerError, "background_delete_failed", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	}))
}
