package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
)

const themeFileName = "theme.json"

var themeHexPattern = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

var allowedPanelThemes = map[string]bool{
	"system": true, "light": true, "dark": true, "mocha": true,
	"parchment": true, "matrix": true, "custom": true,
}

var allowedThemeColors = map[string]bool{
	"bg": true, "surface-sunken": true, "surface": true, "surface-2": true,
	"surface-3": true, "border": true, "border-strong": true,
	"text": true, "text-muted": true, "text-faint": true,
	"accent": true, "accent-strong": true, "accent-hover": true,
	"accent-text": true, "focus-ring": true, "control-knob": true,
	"ok": true, "warn": true, "error": true, "error-strong": true,
	"error-text": true, "muted": true,
	"brand-from": true, "brand-to": true, "brand-text": true,
	"bar-track": true, "bar-fill": true, "bar-fill-warn": true,
	"bar-fill-full": true, "scrim": true,
}

type themeSaveRequest struct {
	Theme  string            `json:"theme"`
	Colors map[string]string `json:"colors"`
}

type themeSettings struct {
	Theme      string            `json:"theme"`
	Colors     map[string]string `json:"colors"`
	Configured bool              `json:"configured"`
}

type themeStore struct {
	mu         sync.RWMutex
	path       string
	settings   themeSaveRequest
	configured bool
}

func newThemeStore(dataDir string) (*themeStore, error) {
	if dataDir == "" {
		return nil, errors.New("data_dir is empty")
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create theme data directory: %w", err)
	}
	s := &themeStore{
		path:     filepath.Join(dataDir, themeFileName),
		settings: themeSaveRequest{Theme: "dark", Colors: map[string]string{}},
	}
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read theme settings: %w", err)
	}
	var saved themeSaveRequest
	if err := json.Unmarshal(raw, &saved); err != nil {
		return nil, fmt.Errorf("parse theme settings: %w", err)
	}
	if err := validateThemeSettings(saved); err != nil {
		return nil, fmt.Errorf("validate theme settings: %w", err)
	}
	s.settings = normalizeThemeSettings(saved)
	s.configured = true
	return s, nil
}

func validateThemeSettings(value themeSaveRequest) error {
	if !allowedPanelThemes[value.Theme] {
		return errors.New("неизвестная тема оформления")
	}
	if len(value.Colors) > len(allowedThemeColors) {
		return errors.New("слишком много цветов в палитре")
	}
	for key, hex := range value.Colors {
		if !allowedThemeColors[key] {
			return fmt.Errorf("неизвестный цветовой параметр %q", key)
		}
		if !themeHexPattern.MatchString(hex) {
			return fmt.Errorf("цвет %q должен быть в формате #RRGGBB", key)
		}
	}
	return nil
}

func normalizeThemeSettings(value themeSaveRequest) themeSaveRequest {
	colors := make(map[string]string, len(value.Colors))
	for key, hex := range value.Colors {
		colors[key] = strings.ToLower(hex)
	}
	return themeSaveRequest{Theme: value.Theme, Colors: colors}
}

func (s *themeStore) get() themeSettings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	colors := make(map[string]string, len(s.settings.Colors))
	for key, hex := range s.settings.Colors {
		colors[key] = hex
	}
	return themeSettings{Theme: s.settings.Theme, Colors: colors, Configured: s.configured}
}

func (s *themeStore) update(next themeSaveRequest) (themeSettings, error) {
	if err := validateThemeSettings(next); err != nil {
		return themeSettings{}, err
	}
	next = normalizeThemeSettings(next)
	s.mu.Lock()
	if err := writeJSONAtomic(s.path, next); err != nil {
		s.mu.Unlock()
		return themeSettings{}, err
	}
	s.settings = next
	s.configured = true
	s.mu.Unlock()
	return s.get(), nil
}

func (s *Server) registerThemeRoutes(mux *http.ServeMux, secret []byte, store *themeStore) {
	mux.HandleFunc("GET /api/theme", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: store.get()})
	})
	mux.Handle("PUT /api/panel/settings/theme", auth.RequireAuth(secret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var next themeSaveRequest
		if err := decoder.Decode(&next); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}
		if err := decoder.Decode(&struct{}{}); err != io.EOF {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}
		if err := validateThemeSettings(next); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_theme", err.Error())
			return
		}
		result, err := store.update(next)
		if err != nil {
			log.Printf("theme settings save: %v", err)
			writeError(w, http.StatusInternalServerError, "theme_save_failed", "Не удалось сохранить тему панели")
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	})))
}
