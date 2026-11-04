package server

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
)

const appearanceMaxSize = 3*maxBrandingImageSize + (1 << 20)

type appearanceManifest struct {
	Format   string           `json:"format"`
	Version  int              `json:"version"`
	Theme    themeSaveRequest `json:"theme"`
	Branding brandingFile     `json:"branding"`
}

func appearanceImage(name string) bool {
	return name == brandingBackgroundName || name == panelBackgroundName || name == "panel-icon"
}

func decodeAppearance(data []byte) (appearanceManifest, map[string][]byte, error) {
	var manifest appearanceManifest
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return manifest, nil, errors.New("нужен ZIP-архив оформления панели")
	}
	if len(reader.File) > 4 {
		return manifest, nil, errors.New("слишком много файлов в архиве")
	}
	files := make(map[string][]byte)
	for _, file := range reader.File {
		if file.Name != "appearance.json" && !appearanceImage(file.Name) {
			return manifest, nil, fmt.Errorf("недопустимый файл: %s", file.Name)
		}
		if _, exists := files[file.Name]; exists || !file.Mode().IsRegular() {
			return manifest, nil, errors.New("дубликаты, каталоги и ссылки запрещены")
		}
		limit := int64(maxBrandingImageSize)
		if file.Name == "appearance.json" {
			limit = 64 << 10
		}
		if file.UncompressedSize64 > uint64(limit) {
			return manifest, nil, errors.New("файл в архиве слишком большой")
		}
		r, err := file.Open()
		if err != nil {
			return manifest, nil, err
		}
		body, err := io.ReadAll(io.LimitReader(r, limit+1))
		r.Close()
		if err != nil || int64(len(body)) > limit {
			return manifest, nil, errors.New("повреждённый или слишком большой файл")
		}
		files[file.Name] = body
		if appearanceImage(file.Name) {
			if _, err := detectPanelImage(body, file.Name == "panel-icon"); err != nil {
				return manifest, nil, err
			}
		}
	}
	d := json.NewDecoder(bytes.NewReader(files["appearance.json"]))
	d.DisallowUnknownFields()
	if err := d.Decode(&manifest); err != nil {
		return manifest, nil, errors.New("некорректное описание оформления")
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		return manifest, nil, errors.New("лишние данные в описании оформления")
	}
	if manifest.Format != "mtproxyl-panel-appearance" || manifest.Version != 1 {
		return manifest, nil, errors.New("неподдерживаемый формат оформления")
	}
	if err := validateThemeSettings(manifest.Theme); err != nil {
		return manifest, nil, err
	}
	manifest.Theme = normalizeThemeSettings(manifest.Theme)
	manifest.Branding = normalizeBrandingFile(manifest.Branding)
	if err := validateBrandingFile(manifest.Branding); err != nil {
		return manifest, nil, err
	}
	if manifest.Branding.PanelBackgroundMode == panelBackgroundCustom && files[panelBackgroundName] == nil {
		return manifest, nil, errors.New("в архиве нет выбранного фона панели")
	}
	if manifest.Branding.PanelBackgroundMode == panelBackgroundLogin && files[brandingBackgroundName] == nil {
		return manifest, nil, errors.New("в архиве нет выбранного фона входа")
	}
	return manifest, files, nil
}

func readAppearanceFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxBrandingImageSize {
		return nil, errors.New("недопустимый файл оформления")
	}
	return os.ReadFile(path)
}

func writeAppearanceFile(path string, data []byte) error {
	if data == nil {
		err := os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".appearance-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func exportAppearance(branding *brandingStore, theme *themeStore) ([]byte, error) {
	branding.mu.RLock()
	defer branding.mu.RUnlock()
	theme.mu.RLock()
	defer theme.mu.RUnlock()
	manifest := appearanceManifest{Format: "mtproxyl-panel-appearance", Version: 1, Theme: theme.settings, Branding: branding.settings}
	body, err := json.Marshal(manifest)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	files := map[string][]byte{"appearance.json": body}
	for _, name := range []string{brandingBackgroundName, panelBackgroundName, "panel-icon"} {
		image, err := readAppearanceFile(filepath.Join(filepath.Dir(theme.path), name))
		if err != nil {
			return nil, err
		}
		if image != nil {
			if _, err := detectPanelImage(image, name == "panel-icon"); err != nil {
				return nil, err
			}
			files[name] = image
		}
	}
	for name, data := range files {
		f, err := w.Create(name)
		if err != nil {
			return nil, err
		}
		if _, err := f.Write(data); err != nil {
			return nil, err
		}
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func importAppearance(data []byte, branding *brandingStore, theme *themeStore) error {
	manifest, images, err := decodeAppearance(data)
	if err != nil {
		return err
	}
	branding.mu.Lock()
	defer branding.mu.Unlock()
	theme.mu.Lock()
	defer theme.mu.Unlock()
	paths := []string{branding.settingsPath, theme.path, branding.backgroundPath, branding.panelBackgroundPath, branding.iconPath}
	old := make(map[string][]byte)
	for _, path := range paths {
		old[path], err = readAppearanceFile(path)
		if err != nil {
			return err
		}
	}
	brandJSON, err := json.Marshal(manifest.Branding)
	if err != nil {
		return err
	}
	themeJSON, err := json.Marshal(manifest.Theme)
	if err != nil {
		return err
	}
	next := map[string][]byte{branding.settingsPath: brandJSON, theme.path: themeJSON,
		branding.backgroundPath: images[brandingBackgroundName], branding.panelBackgroundPath: images[panelBackgroundName], branding.iconPath: images["panel-icon"]}
	for i, path := range paths {
		if err := writeAppearanceFile(path, next[path]); err != nil {
			for _, previous := range paths[:i] {
				if rollbackErr := writeAppearanceFile(previous, old[previous]); rollbackErr != nil {
					return fmt.Errorf("сбой сохранения и отката оформления: %w", rollbackErr)
				}
			}
			return err
		}
	}
	branding.settings = manifest.Branding
	theme.settings, theme.configured = manifest.Theme, true
	return nil
}

func (s *Server) registerAppearanceRoutes(mux *http.ServeMux, secret []byte, branding *brandingStore, theme *themeStore) {
	mux.Handle("GET /api/panel/settings/appearance", auth.RequireAuth(secret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, err := exportAppearance(branding, theme)
		if err != nil {
			writeError(w, 500, "appearance_export_failed", "Не удалось выгрузить оформление: "+err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/zip")
		w.Header().Set("Content-Disposition", `attachment; filename="mtproxyl-panel-appearance.zip"`)
		w.Header().Set("Cache-Control", "no-store")
		w.Write(data)
	})))
	mux.Handle("POST /api/panel/settings/appearance", auth.RequireAuth(secret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, appearanceMaxSize)
		data, err := io.ReadAll(r.Body)
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, "appearance_too_large", "Архив больше 25 МБ или не прочитан")
			return
		}
		if err := importAppearance(data, branding, theme); err != nil {
			writeError(w, 400, "appearance_import_failed", err.Error())
			return
		}
		writeJSON(w, 200, jsonResponse{OK: true, Data: map[string]any{"branding": branding.get(), "theme": theme.get()}})
	})))
}
