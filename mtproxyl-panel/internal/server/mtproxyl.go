package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerMtproxylRoutes wires the /api/mtproxyl/* endpoints, which expose
// MTProxyL's host-level features (mode, selfmask, backups) to the UI.
//
// Routes are registered even when the bridge is disabled, so the frontend gets
// a clear "disabled" answer instead of a 404 it would have to special-case.
func (s *Server) registerMtproxylRoutes(mux *http.ServeMux, jwtSecret []byte) {
	client := mtproxylctl.New(s.cfg.Mtproxyl)
	runner := mtproxylctl.NewRunner()

	protected := func(h http.HandlerFunc) http.Handler {
		return auth.RequireAuth(jwtSecret, h)
	}

	// guard rejects the request when the bridge is off, so each handler below
	// can assume it is enabled.
	guard := func(w http.ResponseWriter) bool {
		if !client.Enabled() {
			writeError(w, http.StatusServiceUnavailable, "mtproxyl_disabled",
				"Интеграция с MTProxyL отключена в конфигурации панели")
			return false
		}
		return true
	}

	// writeCLIError maps a bridge failure onto an HTTP response.
	writeCLIError := func(w http.ResponseWriter, code string, err error) {
		if errors.Is(err, mtproxylctl.ErrDisabled) {
			writeError(w, http.StatusServiceUnavailable, "mtproxyl_disabled",
				"Интеграция с MTProxyL отключена в конфигурации панели")
			return
		}
		writeError(w, http.StatusBadGateway, code, err.Error())
	}

	// ── Availability ────────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/status", protected(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled":   client.Enabled(),
			"operation": runner.Status(),
		}})
	}))

	// ── Mode ────────────────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/mode", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.GetMode(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: st})
	}))

	mux.Handle("POST /api/mtproxyl/mode", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Mode string `json:"mode"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		mode := mtproxylctl.Mode(req.Mode)
		if !mode.Valid() {
			writeError(w, http.StatusBadRequest, "invalid_mode",
				"Режим должен быть manager или reanimator")
			return
		}
		// Switching modes rewrites settings and may remove a container or start
		// a full install, so it runs in the background.
		started := runner.Start("mode:"+string(mode), func(ctx context.Context) (string, error) {
			return "", client.SwitchMode(ctx, mode)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	// ── Selfmask ────────────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/selfmask", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.SelfmaskStatus(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: st})
	}))

	// Setup provisions nginx and possibly issues a certificate — minutes, so
	// it is asynchronous like the mode switch.
	mux.Handle("POST /api/mtproxyl/selfmask/setup", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		started := runner.Start("selfmask:setup", client.SelfmaskSetup)
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("POST /api/mtproxyl/selfmask/verify", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		out, err := client.SelfmaskVerify(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/selfmask/disable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		out, err := client.SelfmaskDisable(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Backups ─────────────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/backups", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		list, err := client.ListBackups(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: list})
	}))

	mux.Handle("POST /api/mtproxyl/backups", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		name, err := client.CreateBackup(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"name": name}})
	}))

	mux.Handle("POST /api/mtproxyl/backups/restore", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		// Reject a bad name before starting the job, so the user sees the
		// validation error directly instead of having to poll for it.
		if err := mtproxylctl.ValidateBackupName(req.Name); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_backup_name",
				"Недопустимое имя файла бэкапа")
			return
		}
		name := req.Name
		started := runner.Start("backup:restore", func(ctx context.Context) (string, error) {
			return client.RestoreBackup(ctx, name)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("GET /api/mtproxyl/backups/{name}/download", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		path, err := client.ResolveBackupPath(r.PathValue("name"))
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_backup_name",
				"Недопустимое имя файла бэкапа")
			return
		}
		f, err := os.Open(path)
		if err != nil {
			if os.IsNotExist(err) {
				writeError(w, http.StatusNotFound, "not_found", "Бэкап не найден")
				return
			}
			// Backups are chmod 600 and owned by root; an unprivileged panel
			// cannot read them directly even though it can create them.
			writeError(w, http.StatusForbidden, "read_failed",
				"Нет доступа к файлу бэкапа: "+err.Error())
			return
		}
		defer f.Close()

		info, err := f.Stat()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "stat_failed", err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/gzip")
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		w.Header().Set("Content-Disposition",
			`attachment; filename="`+filepath.Base(path)+`"`)
		http.ServeContent(w, r, filepath.Base(path), info.ModTime(), f)
	}))
}
