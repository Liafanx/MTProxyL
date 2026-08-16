package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerWarpRoutes wires «Telegram через WARP». Turning it on scans Cloudflare
// endpoints and takes minutes, so it goes through the same operation runner as
// mode switches — the request returns at once and the panel follows the log.
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

	// start hands a long command to the runner; a busy runner is a conflict,
	// not a failure — the caller retries when the current one finishes.
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
			Mode string `json:"mode"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Ожидается {\"mode\": \"socks\"|\"iface\"}")
			return
		}
		if req.Mode != "socks" && req.Mode != "iface" {
			writeError(w, http.StatusBadRequest, "invalid_mode", "Вариант: socks (A) или iface (B)")
			return
		}
		mode := req.Mode
		start(w, "warp:on:"+mode, func(ctx context.Context) (string, error) {
			return client.WarpEnable(ctx, mode)
		})
	}))

	mux.Handle("POST /api/warp/disable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "warp:off", client.WarpDisable)
	}))

	mux.Handle("POST /api/warp/scan", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "warp:scan", client.WarpScan)
	}))

	mux.Handle("POST /api/warp/reapply", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "warp:reapply", client.WarpReapply)
	}))

	// Настройки применяются со следующей разведкой, менять их можно и на
	// выключенном WARP — поэтому они не идут через runner.
	mux.Handle("PUT /api/warp/settings", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
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
		if req.Proto != nil {
			if _, err := client.WarpSetProto(r.Context(), *req.Proto); err != nil {
				writeCLIError(w, "warp_proto_failed", err)
				return
			}
		}
		if req.Location != nil {
			if _, err := client.WarpSetLocation(r.Context(), *req.Location); err != nil {
				writeCLIError(w, "warp_location_failed", err)
				return
			}
		}
		if req.Endpoint != nil {
			if _, err := client.WarpSetEndpoint(r.Context(), *req.Endpoint); err != nil {
				writeCLIError(w, "warp_endpoint_failed", err)
				return
			}
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
