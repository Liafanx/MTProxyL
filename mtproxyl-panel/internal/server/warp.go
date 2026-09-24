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

// registerWarpRoutes wires «Telegram через WARP»: enabling scans endpoints for
// minutes, so it goes through the same operation runner as mode switches.
func (s *Server) registerWarpRoutes(
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

	// start hands a long command to the runner; busy is a conflict, not a failure.
	start := func(w http.ResponseWriter, name string, fn func(context.Context) (string, error)) {
		if !runner.Start(name, fn) {
			writeError(w, http.StatusConflict, "operation_busy",
				"Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}

	mux.Handle("GET /api/warp/status", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.WarpGetStatus(r.Context())
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrWarpUnsupported) {
				writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
					"supported": false,
					"message":   "Установленный MTProxyL не умеет маршрут через WARP — обновите его: mtproxyl update",
				}})
				return
			}
			writeCLIError(w, "warp_status_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
		}})
	}))

	mux.Handle("POST /api/warp/enable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Mode                         string `json:"mode"`
			AllowDisableMiddleProxy      bool   `json:"allow_disable_middle_proxy"`
			AllowDisableDefaultUpstreams bool   `json:"allow_disable_default_upstreams"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Ожидается {\"mode\": \"socks\"|\"iface\"|\"upstream\"}")
			return
		}
		switch req.Mode {
		case "socks", "iface", "upstream":
		default:
			writeError(w, http.StatusBadRequest, "invalid_mode", "Вариант: socks (A), iface (B) или upstream (C)")
			return
		}
		mode := req.Mode
		allowME := req.AllowDisableMiddleProxy
		allowRoutes := req.AllowDisableDefaultUpstreams
		start(w, "warp:on:"+mode, func(ctx context.Context) (string, error) {
			return client.WarpEnable(ctx, mode, allowME, allowRoutes)
		})
	}))

	mux.Handle("GET /api/warp/preflight", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		result, err := client.WarpPreflight(r.Context(), r.URL.Query().Get("mode"))
		if err != nil {
			writeCLIError(w, "warp_preflight_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	}))

	mux.Handle("POST /api/warp/disable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "warp:off", client.WarpDisable)
	}))

	mux.Handle("GET /api/warp/scan", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		res, err := client.WarpGetScan(r.Context())
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrWarpUnsupported) {
				writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
					"supported": false,
				}})
				return
			}
			writeCLIError(w, "warp_scan_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"scan":      res,
		}})
	}))

	mux.Handle("POST /api/warp/scan", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Mode string `json:"mode"`
			Deep bool   `json:"deep"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "bad_request", "Неверный запрос разведки")
			return
		}
		switch req.Mode {
		case "", "socks", "iface", "upstream":
		default:
			writeError(w, http.StatusBadRequest, "invalid_mode", "Неверный вариант WARP")
			return
		}
		start(w, "warp:scan", func(ctx context.Context) (string, error) { return client.WarpScanMode(ctx, req.Mode, req.Deep) })
	}))

	for _, action := range []string{"apply", "recover", "install", "watchdog-on", "watchdog-off"} {
		mux.Handle("POST /api/warp/"+action, protected(func(w http.ResponseWriter, r *http.Request) {
			if !guard(w) {
				return
			}
			start(w, "warp:"+action, func(ctx context.Context) (string, error) { return client.WarpAction(ctx, action) })
		}))
	}

	mux.Handle("POST /api/warp/reapply", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "warp:reapply", client.WarpReapply)
	}))

	// Сохранение выбора не переключает работающий туннель.
	mux.Handle("PUT /api/warp/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		if runner.Busy() {
			writeError(w, http.StatusConflict, "operation_busy", "Дождитесь завершения текущей операции")
			return
		}
		var req struct {
			Location *string `json:"location"`
			Endpoint *string `json:"endpoint"`
			Proto    *string `json:"proto"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<10)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}
		if _, err := client.WarpSetSettings(r.Context(), req.Proto, req.Location, req.Endpoint); err != nil {
			writeCLIError(w, "warp_settings_failed", err)
			return
		}
		st, err := client.WarpGetStatus(r.Context())
		if err != nil {
			writeCLIError(w, "warp_status_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
		}})
	}))
}
