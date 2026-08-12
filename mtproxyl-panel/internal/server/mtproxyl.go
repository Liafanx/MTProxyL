package server

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerMtproxylRoutes wires /api/mtproxyl/* — MTProxyL's host-level features.
// Registered even when the bridge is off, so the frontend gets a clear
// "disabled" answer instead of a 404 it would have to special-case.
func (s *Server) registerMtproxylRoutes(mux *http.ServeMux, jwtSecret []byte) {
	client := mtproxylctl.New(s.cfg.Mtproxyl)
	runner := mtproxylctl.NewRunner()
	telemtURL := s.cfg.Telemt.URL

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

	// busy rejects a state-changing request while a background operation runs:
	// those rewrite settings files wholesale. Read-only checks are not gated.
	busy := func(w http.ResponseWriter) bool {
		if runner.Busy() {
			writeError(w, http.StatusConflict, "operation_busy",
				"Дождитесь завершения текущей операции MTProxyL")
			return true
		}
		return false
	}

	// ── Availability ────────────────────────────────────────────────────────
	// Mode travels with the probe: several features are manager-only, and the UI
	// hides them rather than offering buttons guaranteed to fail.
	mux.Handle("GET /api/mtproxyl/status", protected(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"enabled":   client.Enabled(),
			"operation": runner.Status(),
			"mode":      "",
		}
		if client.Enabled() {
			// A failure here must not break the probe: the UI still needs to
			// know the bridge is on, even if the mode could not be read.
			if st, err := cachedMode(r.Context(), client); err == nil {
				resp["mode"] = string(st.Mode)
				// The panel talks to one fixed telemt URL chosen at install time;
				// a mode switch does not change it, so the dashboard can show the
				// other engine's data as its own.
				if mismatch := apiEndpointMismatch(telemtURL, st); mismatch != "" {
					resp["api_mismatch"] = mismatch
					resp["api_expected_port"] = st.APIPort
				}
				resp["api_enabled"] = st.APIEnabled
			} else {
				log.Printf("[mtproxyl] could not read mode: %s", err)
			}
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: resp})
	}))

	// ── Operation slot ──────────────────────────────────────────────────────
	// Closing the log panel has to reach the server: the slot is shared between
	// tabs and survives reloads.
	mux.Handle("POST /api/mtproxyl/operation/dismiss", protected(func(w http.ResponseWriter, r *http.Request) {
		if !runner.Dismiss() {
			writeError(w, http.StatusConflict, "operation_busy",
				"Операция ещё выполняется — дождитесь её завершения")
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: runner.Status()})
	}))

	// ── Обновление самого MTProxyL ──────────────────────────────────────────
	// Версия CLI живёт вне панели: обновляет себя сам скрипт, панель только
	// показывает, что вышло новое, и нажимает кнопку.
	mux.Handle("GET /api/mtproxyl/update", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		info, err := cachedUpdateInfo(r.Context(), client, r.URL.Query().Get("refresh") == "1")
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: info})
	}))

	mux.Handle("POST /api/mtproxyl/update/apply", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		if busy(w) {
			return
		}
		// Скрипт, не знающий --no-restart, проглотит флаг и уйдёт в exec
		// интерактивного меню — операция провисит до таймаута. Проверка
		// версии заодно подтверждает, что флаг понимают.
		if _, err := cachedUpdateInfo(r.Context(), client, false); err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		started := runner.Start("update:mtproxyl", func(ctx context.Context) (string, error) {
			defer invalidateUpdateCache()
			return client.ApplyUpdate(ctx)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
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
			// Container says what to do with MTProxyL's own container when
			// leaving manager mode. Required for reanimator: the CLI's own
			// default deletes it, and that has to be the user's decision.
			Container string `json:"container"`
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
		disposition := mtproxylctl.ContainerDisposition(req.Container)
		if mode == mtproxylctl.ModeReanimator && !disposition.Valid() {
			writeError(w, http.StatusBadRequest, "invalid_container_disposition",
				"Укажите, что делать со своим контейнером: remove, stop или keep")
			return
		}
		// Switching modes rewrites settings and may remove a container or start
		// a full install, so it runs in the background.
		started := runner.Start("mode:"+string(mode), func(ctx context.Context) (string, error) {
			// The cached mode is stale the moment the switch begins, and the UI
			// polls this endpoint throughout — leaving it would report the old
			// mode for seconds after the switch landed.
			defer invalidateModeCache()
			invalidateModeCache()
			return "", client.SwitchMode(ctx, mode, disposition)
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

	// Settable parameters: the UI edits them, then applies.
	mux.Handle("GET /api/mtproxyl/selfmask/params", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		list, err := client.SelfmaskParams(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: list})
	}))

	mux.Handle("POST /api/mtproxyl/selfmask/params", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := mtproxylctl.ValidateSelfmaskParam(req.Key, req.Value); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_param", "Недопустимый параметр или значение")
			return
		}
		out, err := client.SetSelfmaskParam(r.Context(), req.Key, req.Value)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// Applying provisions nginx and may issue a certificate — minutes, so it is
	// asynchronous like the mode switch. It uses the stored parameters rather
	// than MTProxyL's interactive wizard, which would ignore them.
	mux.Handle("POST /api/mtproxyl/selfmask/apply", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		started := runner.Start("selfmask:apply", client.SelfmaskApply)
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
		if !guard(w) || busy(w) {
			return
		}
		out, err := client.SelfmaskDisable(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Настройки MTProxyL ──────────────────────────────────────────────────
	// Живут в settings.conf, а не в конфиге движка: в Manager тот примонтирован
	// только для чтения.
	mux.Handle("GET /api/mtproxyl/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		list, err := client.Settings(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: list})
	}))

	mux.Handle("POST /api/mtproxyl/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := mtproxylctl.ValidateSetting(req.Key, req.Value); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_param", "Недопустимый параметр или значение")
			return
		}
		out, err := client.SetSetting(r.Context(), req.Key, req.Value)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Пользователи (секреты MTProxyL) ─────────────────────────────────────
	// В Manager движок не может записать пользователя («Device or resource busy»),
	// владелец здесь MTProxyL — панель ходит через его CLI.
	// Всё закрыто busy(): восстановление бэкапа переписывает secrets.conf целиком.
	mux.Handle("GET /api/mtproxyl/users", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		list, err := cachedUsers(r.Context(), client)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: list})
	}))

	mux.Handle("POST /api/mtproxyl/users", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Label  string `json:"label"`
			Secret string `json:"secret"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		out, err := client.AddSecret(r.Context(), req.Label, req.Secret)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		invalidateUsersCache()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("DELETE /api/mtproxyl/users/{label}", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		out, err := client.RemoveSecret(r.Context(), r.PathValue("label"))
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		invalidateUsersCache()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/users/{label}/limits", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var limits mtproxylctl.SecretLimits
		if err := json.NewDecoder(r.Body).Decode(&limits); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		out, err := client.SetSecretLimits(r.Context(), r.PathValue("label"), limits)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		invalidateUsersCache()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/users/{label}/toggle", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Enabled bool `json:"enabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		out, err := client.ToggleSecret(r.Context(), r.PathValue("label"), req.Enabled)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		invalidateUsersCache()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/users/{label}/rotate", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		out, err := client.RotateSecret(r.Context(), r.PathValue("label"))
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		invalidateUsersCache()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/users/{label}/rename", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			To string `json:"to"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		out, err := client.RenameSecret(r.Context(), r.PathValue("label"), req.To)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		invalidateUsersCache()
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
		if !guard(w) || busy(w) {
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

	// ── NFT limiter, iOS fixes, Zapret2 ─────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/nft", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.NftStatus(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: st})
	}))

	// Parameters are stored, not applied: the caller runs an action afterwards,
	// mirroring how MTProxyL's own menu separates the two steps.
	mux.Handle("POST /api/mtproxyl/nft/params", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := mtproxylctl.ValidateNftParam(req.Key, req.Value); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_param", "Недопустимый параметр или значение")
			return
		}
		out, err := client.SetNftParam(r.Context(), req.Key, req.Value)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// Applying rules can take a while (Zapret2 downloads a bundle), so these run
	// in the background like the other long operations.
	mux.Handle("POST /api/mtproxyl/nft/action", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		action := mtproxylctl.NftAction(req.Action)
		if !mtproxylctl.ValidNftAction(action) {
			writeError(w, http.StatusBadRequest, "invalid_action", "Неизвестное действие")
			return
		}
		started := runner.Start("nft:"+req.Action, func(ctx context.Context) (string, error) {
			return client.RunNftAction(ctx, action)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("POST /api/mtproxyl/nft/preset", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Preset string `json:"preset"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if req.Preset != "classic" && req.Preset != "smart" {
			writeError(w, http.StatusBadRequest, "invalid_preset", "Режим: classic или smart")
			return
		}
		preset := req.Preset
		started := runner.Start("nft:preset:"+preset, func(ctx context.Context) (string, error) {
			return client.NftPreset(ctx, preset)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	// ── Geoblock ────────────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/geoblock", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.GeoblockList(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: st})
	}))

	// Adding a country downloads its CIDR ranges, which is slow on first use.
	mux.Handle("POST /api/mtproxyl/geoblock", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Country string `json:"country"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := mtproxylctl.ValidateCountryCode(req.Country); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_country", "Код страны: две буквы")
			return
		}
		code := req.Country
		started := runner.Start("geoblock:add:"+code, func(ctx context.Context) (string, error) {
			return client.GeoblockAdd(ctx, code)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("DELETE /api/mtproxyl/geoblock/{country}", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		code := r.PathValue("country")
		if err := mtproxylctl.ValidateCountryCode(code); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_country", "Код страны: две буквы")
			return
		}
		out, err := client.GeoblockRemove(r.Context(), code)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Proxy control ───────────────────────────────────────────────────────
	// Работает в обоих режимах: CLI сам решает, что запускать. Унаследованный
	// /api/telemt/restart дёргает systemctl и в Manager бесполезен.
	mux.Handle("POST /api/mtproxyl/proxy/{action}", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		action := mtproxylctl.ProxyAction(r.PathValue("action"))
		if !action.Valid() {
			writeError(w, http.StatusBadRequest, "invalid_action",
				"Действие должно быть start, stop или restart")
			return
		}
		started := runner.Start("proxy:"+string(action), func(ctx context.Context) (string, error) {
			// Состояние движка меняется — закэшированный ответ mode --json
			// сообщал бы прежнее running ещё несколько секунд.
			defer invalidateModeCache()
			return client.ControlProxy(ctx, action)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	// ── Traffic ─────────────────────────────────────────────────────────────
	// Работает в обоих режимах: в реаниматоре CLI берёт числа у цели.
	mux.Handle("GET /api/mtproxyl/traffic", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		rep, err := client.Traffic(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: rep})
	}))

	// ── Upstream routes ─────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/upstreams", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		list, err := client.UpstreamList(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: list})
	}))

	mux.Handle("POST /api/mtproxyl/upstreams", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var spec mtproxylctl.UpstreamSpec
		if err := json.NewDecoder(r.Body).Decode(&spec); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := spec.Validate(); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_upstream", err.Error())
			return
		}
		out, err := client.UpstreamAdd(r.Context(), spec)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("DELETE /api/mtproxyl/upstreams/{name}", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		name := r.PathValue("name")
		if err := mtproxylctl.ValidateUpstreamName(name); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_upstream", "Недопустимое имя маршрута")
			return
		}
		out, err := client.UpstreamRemove(r.Context(), name)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/upstreams/{name}/toggle", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		name := r.PathValue("name")
		if err := mtproxylctl.ValidateUpstreamName(name); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_upstream", "Недопустимое имя маршрута")
			return
		}
		var req struct {
			Enabled bool `json:"enabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		out, err := client.UpstreamToggle(r.Context(), name, req.Enabled)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/upstreams/{name}/test", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		name := r.PathValue("name")
		if err := mtproxylctl.ValidateUpstreamName(name); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_upstream", "Недопустимое имя маршрута")
			return
		}
		out, err := client.UpstreamTest(r.Context(), name)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Expert catalog ──────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/expert", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		list, err := client.ExpertCatalog(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: list})
	}))

	mux.Handle("POST /api/mtproxyl/expert", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Section string `json:"section"`
			Key     string `json:"key"`
			Value   string `json:"value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := mtproxylctl.ValidateExpertParam(req.Section, req.Key, req.Value); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_param", "Недопустимый параметр или значение")
			return
		}
		out, err := client.SetExpertParam(r.Context(), req.Section, req.Key, req.Value)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("DELETE /api/mtproxyl/expert/{section}/{key}", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		section, key := r.PathValue("section"), r.PathValue("key")
		if err := mtproxylctl.ValidateExpertTarget(section, key); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_param", "Недопустимый параметр")
			return
		}
		out, err := client.ClearExpertParam(r.Context(), section, key)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Addons ──────────────────────────────────────────────────────────────
	// Только PQ-проверка домена и установка инструментов PQ. censorcheck не
	// перенесён намеренно: он выполняет сторонний скрипт из сети.
	mux.Handle("POST /api/mtproxyl/pq-install", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		started := runner.Start("selfmask:pq-install", client.InstallPQTools)
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("POST /api/mtproxyl/pq-check", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Domain string `json:"domain"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		if err := mtproxylctl.ValidatePQDomain(req.Domain); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_domain", "Недопустимый домен")
			return
		}
		out, err := client.PQCheck(r.Context(), req.Domain)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// GeoIP: databases live in a system directory, not the target's config, so
	// installing works the same in manager and reanimator mode.
	mux.Handle("GET /api/mtproxyl/geoip-status", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.GeoIPStatus(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: st})
	}))

	mux.Handle("POST /api/mtproxyl/geoip-install", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		started := runner.Start("geoip:install", func(ctx context.Context) (string, error) {
			defer invalidateGeoIPLookup()
			return client.InstallGeoIP(ctx)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	// Applying rebuilds the engine config once for a whole batch of edits.
	mux.Handle("POST /api/mtproxyl/expert/apply", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		out, err := client.ApplyExpert(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	// ── Super expert ────────────────────────────────────────────────────────
	mux.Handle("GET /api/mtproxyl/superexpert", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.SuperExpertStatus(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: st})
	}))

	mux.Handle("GET /api/mtproxyl/superexpert/config", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		content, err := client.SuperExpertRead(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"content": content}})
	}))

	mux.Handle("PUT /api/mtproxyl/superexpert/config", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Content string `json:"content"`
		}
		// The engine config can be sizeable; cap it so a runaway body cannot be
		// buffered without bound.
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		out, err := client.SuperExpertWrite(r.Context(), req.Content)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/mtproxyl/superexpert/toggle", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Enabled bool `json:"enabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", "Некорректное тело запроса")
			return
		}
		var (
			out string
			err error
		)
		if req.Enabled {
			out, err = client.SuperExpertEnable(r.Context())
		} else {
			out, err = client.SuperExpertDisable(r.Context())
		}
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("GET /api/mtproxyl/backups/{name}/download", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		name := r.PathValue("name")
		// Читаем через привилегированную команду: архив лежит root:600, и
		// прямое открытие файла из-под пользователя панели упиралось в
		// permission denied — кнопка «скачать» отдавала только ошибку.
		data, err := client.ReadBackup(r.Context(), name)
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrInvalidBackupName) {
				writeError(w, http.StatusBadRequest, "invalid_backup_name",
					"Недопустимое имя файла бэкапа")
				return
			}
			if errors.Is(err, mtproxylctl.ErrBackupNotFound) {
				writeError(w, http.StatusNotFound, "not_found", "Бэкап не найден")
				return
			}
			writeCLIError(w, "read_failed", err)
			return
		}

		w.Header().Set("Content-Type", "application/gzip")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.Header().Set("Content-Disposition",
			`attachment; filename="`+filepath.Base(name)+`"`)
		if _, err := w.Write(data); err != nil {
			log.Printf("[mtproxyl] не удалось отдать бэкап %s: %s", name, err)
		}
	}))

	// ── Телеграм-бот ────────────────────────────────────────────────────────
	// Ставит и настраивает бота тот же CLI; панель показывает состояние и
	// нажимает кнопки. Доступно в обоих режимах — бот от режима не зависит,
	// только бэкапы внутри него отключаются в реаниматоре.
	tgbotStatus := func(w http.ResponseWriter, r *http.Request) {
		st, err := client.TgbotStatus(r.Context())
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrTgbotUnsupported) {
				writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
					"supported": false,
					"message": "Установленный MTProxyL не умеет управлять телеграм-ботом — " +
						"обновите его: mtproxyl update",
				}})
				return
			}
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
			"hint":      mtproxylctl.TgbotTokenHint(),
			"operation": runner.Status(),
		}})
	}

	mux.Handle("GET /api/tgbot/status", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		tgbotStatus(w, r)
	}))

	mux.Handle("GET /api/tgbot/logs", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		lines, _ := strconv.Atoi(r.URL.Query().Get("lines"))
		out, err := client.TgbotLogs(r.Context(), lines)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"lines": out}})
	}))

	// Установка тянет venv и aiogram — это минуты, поэтому она уходит в тот же
	// раннер, что и прочие долгие операции, с журналом по шагам.
	mux.Handle("POST /api/tgbot/install", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var body struct {
			Token string `json:"token"`
			Admin int64  `json:"admin"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}
		token := strings.TrimSpace(body.Token)
		if token != "" {
			if err := mtproxylctl.ValidateTgbotToken(token); err != nil {
				writeError(w, http.StatusBadRequest, "invalid_token", err.Error())
				return
			}
			if body.Admin <= 0 {
				writeError(w, http.StatusBadRequest, "invalid_admin",
					"Нужен числовой Telegram ID администратора")
				return
			}
		} else {
			// Пустые поля — это «переустановить с прежним токеном». Если
			// прежнего нет, скрипту пришлось бы спрашивать, а терминала у него
			// тут не будет: лучше отказать сразу и объяснить, чем оставить
			// операцию висеть.
			st, err := client.TgbotStatus(r.Context())
			if err != nil {
				writeCLIError(w, "mtproxyl_error", err)
				return
			}
			if !st.Configured {
				writeError(w, http.StatusBadRequest, "token_required",
					"Бот ещё не настроен: укажите токен от @BotFather и свой Telegram ID")
				return
			}
		}
		started := runner.Start("tgbot:install", func(ctx context.Context) (string, error) {
			return client.TgbotInstall(ctx, token, body.Admin)
		})
		if !started {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("POST /api/tgbot/service", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var body struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}
		// Обновление кода перекачивает файлы и перезапускает службу — секунды,
		// но не мгновение; остальное быстро.
		out, err := client.TgbotService(r.Context(), body.Action)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/tgbot/uninstall", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		out, err := client.TgbotUninstall(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))

	mux.Handle("POST /api/tgbot/admins", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var body struct {
			ID     int64 `json:"id"`
			Remove bool  `json:"remove"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}
		if _, err := client.TgbotAdmin(r.Context(), body.ID, !body.Remove); err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		tgbotStatus(w, r)
	}))

	mux.Handle("PUT /api/tgbot/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var body struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}
		if _, err := client.TgbotSet(r.Context(), body.Key, strings.TrimSpace(body.Value)); err != nil {
			var ce *mtproxylctl.CommandError
			if errors.As(err, &ce) {
				writeCLIError(w, "mtproxyl_error", err)
				return
			}
			writeError(w, http.StatusBadRequest, "invalid_setting", err.Error())
			return
		}
		tgbotStatus(w, r)
	}))
}
