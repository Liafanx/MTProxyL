package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerAwgRoutes wires «Telegram через свой AWG»: импорт клиентского
// конфига и включение. Включение перезапускает движок — через runner.
func (s *Server) registerAwgRoutes(
	mux *http.ServeMux,
	jwtSecret []byte,
	client *mtproxylctl.Client,
	runner *mtproxylctl.Runner,
) {
	protected := func(h http.HandlerFunc) http.Handler {
		return auth.RequireAuth(jwtSecret, h)
	}

	guard := func(w http.ResponseWriter) bool {
		if !client.Enabled() {
			writeError(w, http.StatusServiceUnavailable, "mtproxyl_disabled",
				"Интеграция с MTProxyL отключена в конфигурации панели")
			return false
		}
		return true
	}

	start := func(w http.ResponseWriter, name string, fn func(context.Context) (string, error)) {
		if !runner.Start(name, fn) {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}

	decode := func(w http.ResponseWriter, r *http.Request, v any, limit int64) bool {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit)).Decode(v); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return false
		}
		return true
	}

	// Операции, меняющие маршрут, не идут параллельно с работающей.
	busy := func(w http.ResponseWriter) bool {
		if runner.Busy() {
			writeError(w, http.StatusConflict, "operation_busy", "Дождитесь завершения текущей операции")
			return true
		}
		return false
	}

	// Через что движок выходит к Telegram — для дашборда.
	mux.Handle("GET /api/egress", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		e, err := client.GetEgress(r.Context())
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrEgressUnsupported) {
				writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": false}})
				return
			}
			writeCLIError(w, "egress_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": true, "egress": e}})
	}))

	mux.Handle("GET /api/awg/status", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.AwgGetStatus(r.Context())
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrAwgUnsupported) {
				writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
					"supported": false,
					"message":   "Установленный MTProxyL не умеет выход через свой AWG — обновите его: mtproxyl update",
				}})
				return
			}
			writeCLIError(w, "awg_status_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
		}})
	}))

	mux.Handle("GET /api/awg/scan", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		files, err := client.AwgScan(r.Context())
		if err != nil {
			writeCLIError(w, "awg_scan_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"files": files}})
	}))

	mux.Handle("POST /api/awg/import", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Name string `json:"name"`
			Body string `json:"body"`
			Path string `json:"path"`
		}
		// Тело конфига — до 64 КБ, в JSON экранирование раздувает его.
		if !decode(w, r, &req, 4*mtproxylctl.AwgConfigMax) {
			return
		}
		if err := mtproxylctl.ValidateAwgName(req.Name); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_name", err.Error())
			return
		}
		var out string
		var err error
		switch {
		case req.Path != "" && req.Body == "":
			if verr := mtproxylctl.ValidateAwgPath(req.Path); verr != nil {
				writeError(w, http.StatusBadRequest, "invalid_path", verr.Error())
				return
			}
			out, err = client.AwgImportPath(r.Context(), req.Path, req.Name)
		case req.Body != "" && req.Path == "":
			out, err = client.AwgImport(r.Context(), req.Name, req.Body)
		default:
			writeError(w, http.StatusBadRequest, "bad_request", "Нужен либо файл, либо путь к нему")
			return
		}
		if err != nil {
			writeCLIError(w, "awg_import_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"output": out}})
	}))

	mux.Handle("POST /api/awg/enable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req mtproxylctl.AwgEnableRequest
		if !decode(w, r, &req, 4<<10) {
			return
		}
		if err := req.Validate(); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
			return
		}
		start(w, "awg:on", func(ctx context.Context) (string, error) {
			return client.AwgEnable(ctx, req)
		})
	}))

	mux.Handle("POST /api/awg/order", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Names []string `json:"names"`
		}
		if !decode(w, r, &req, 4<<10) {
			return
		}
		if err := mtproxylctl.ValidateAwgOrder(req.Names); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
			return
		}
		// Смена порядка может сразу переключить выход — через runner.
		start(w, "awg:order", func(ctx context.Context) (string, error) {
			return client.AwgOrder(ctx, req.Names)
		})
	}))

	mux.Handle("POST /api/awg/timers", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			FailoverAfter int `json:"failover_after"`
			FailbackEvery int `json:"failback_every"`
		}
		if !decode(w, r, &req, 1<<10) {
			return
		}
		if err := mtproxylctl.ValidateAwgTimers(req.FailoverAfter, req.FailbackEvery); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
			return
		}
		if _, err := client.AwgTimers(r.Context(), req.FailoverAfter, req.FailbackEvery); err != nil {
			writeCLIError(w, "awg_timers_failed", err)
			return
		}
		st, err := client.AwgGetStatus(r.Context())
		if err != nil {
			writeCLIError(w, "awg_status_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": true, "status": st}})
	}))

	mux.Handle("POST /api/awg/disable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "awg:off", client.AwgDisable)
	}))

	mux.Handle("POST /api/awg/check", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		// Неудачная проверка — тоже ответ: результат читается из статуса.
		_, _ = client.AwgCheck(r.Context())
		st, err := client.AwgGetStatus(r.Context())
		if err != nil {
			writeCLIError(w, "awg_check_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
		}})
	}))

	mux.Handle("POST /api/awg/remove", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Name string `json:"name"`
		}
		if !decode(w, r, &req, 4<<10) {
			return
		}
		out, err := client.AwgRemove(r.Context(), req.Name)
		if err != nil {
			writeCLIError(w, "awg_remove_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"output": out}})
	}))
}
