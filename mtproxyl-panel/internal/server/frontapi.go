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

// registerFrontRoutes — держатель заглушки (nginx/Caddy/HAProxy) и внешний
// API управления. Перенос держателя ставит сборку, поэтому через runner.
func (s *Server) registerFrontRoutes(
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
	busy := func(w http.ResponseWriter) bool {
		if runner.Busy() {
			writeError(w, http.StatusConflict, "operation_busy",
				"Дождитесь завершения текущей операции MTProxyL")
			return true
		}
		return false
	}
	decode := func(w http.ResponseWriter, r *http.Request, v any) bool {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(v); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return false
		}
		return true
	}

	mux.Handle("GET /api/mtproxyl/front", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.FrontStatus(r.Context())
		if errors.Is(err, mtproxylctl.ErrFrontUnsupported) {
			writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": false}})
			return
		}
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": true, "status": st}})
	}))

	mux.Handle("POST /api/mtproxyl/front", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Server string `json:"server"`
		}
		if !decode(w, r, &req) {
			return
		}
		switch req.Server {
		case "nginx", "caddy", "haproxy":
		default:
			writeError(w, http.StatusBadRequest, "bad_request", "Держатель: nginx, caddy или haproxy")
			return
		}
		if !runner.Start("front:"+req.Server, func(ctx context.Context) (string, error) {
			return client.SetFront(ctx, req.Server)
		}) {
			writeError(w, http.StatusConflict, "operation_busy", "Другая операция MTProxyL уже выполняется")
			return
		}
		writeJSON(w, http.StatusAccepted, jsonResponse{OK: true, Data: runner.Status()})
	}))

	mux.Handle("GET /api/mtproxyl/api", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.APIStatus(r.Context())
		if err != nil {
			writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": false}})
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"supported": true, "status": st}})
	}))

	// Включение может скачивать бинарник — но это секунды, а ключ надо
	// вернуть в ответе, поэтому без runner.
	mux.Handle("POST /api/mtproxyl/api/toggle", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Enabled bool `json:"enabled"`
		}
		if !decode(w, r, &req) {
			return
		}
		out, key, err := client.APIToggle(r.Context(), req.Enabled)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out, "key": key}})
	}))

	mux.Handle("POST /api/mtproxyl/api/key", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		key, err := client.APIRotateKey(r.Context())
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"key": key}})
	}))

	mux.Handle("POST /api/mtproxyl/api/set", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) || busy(w) {
			return
		}
		var req struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if !decode(w, r, &req) {
			return
		}
		out, err := client.APISet(r.Context(), req.Key, req.Value)
		if err != nil {
			writeCLIError(w, "mtproxyl_error", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"output": out}})
	}))
}
