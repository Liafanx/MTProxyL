package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerDonorRoutes wires «Туннель AWG до сервера-донора». Setup installs
// packages on two machines, so it runs through the operation runner.
func (s *Server) registerDonorRoutes(
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

	decode := func(w http.ResponseWriter, r *http.Request, v any) bool {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(v); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return false
		}
		return true
	}

	mux.Handle("GET /api/donor/status", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.DonorGetStatus(r.Context())
		if err != nil {
			if errors.Is(err, mtproxylctl.ErrDonorUnsupported) {
				writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
					"supported": false,
					"message":   "Установленный MTProxyL не умеет туннель до донора — обновите его: mtproxyl update",
				}})
				return
			}
			writeCLIError(w, "donor_status_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
		}})
	}))

	mux.Handle("GET /api/donor/hostkey", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		port := 22
		if p := r.URL.Query().Get("port"); p != "" {
			v, err := strconv.Atoi(p)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_port", "Неверный порт SSH")
				return
			}
			port = v
		}
		keys, err := client.DonorHostKeys(r.Context(), r.URL.Query().Get("host"), port)
		if err != nil {
			writeCLIError(w, "donor_hostkey_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"fingerprints": keys}})
	}))

	mux.Handle("POST /api/donor/setup", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Host                         string `json:"host"`
			SSHPort                      int    `json:"ssh_port"`
			User                         string `json:"user"`
			Password                     string `json:"password"`
			AwgPort                      int    `json:"awg_port"`
			Mtu                          int    `json:"mtu"`
			HostKey                      string `json:"host_key"`
			AllowDisableDefaultUpstreams bool   `json:"allow_disable_default_upstreams"`
		}
		if !decode(w, r, &req) {
			return
		}
		if req.SSHPort == 0 {
			req.SSHPort = 22
		}
		if req.User == "" {
			req.User = "root"
		}
		setup := mtproxylctl.DonorSetupRequest{
			Host: req.Host, SSHPort: req.SSHPort, User: req.User, Password: req.Password,
			AwgPort: req.AwgPort, Mtu: req.Mtu, HostKey: req.HostKey,
			AllowDisableDefaultUpstreams: req.AllowDisableDefaultUpstreams,
		}
		// Проверяем до запуска: ошибка ввода — это 400, а не упавшая операция.
		if err := setup.Validate(); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
			return
		}
		start(w, "donor:setup", func(ctx context.Context) (string, error) {
			return client.DonorSetup(ctx, setup)
		})
	}))

	mux.Handle("POST /api/donor/manual", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		if runner.Busy() {
			writeError(w, http.StatusConflict, "operation_busy", "Дождитесь завершения текущей операции")
			return
		}
		var req struct {
			Host    string `json:"host"`
			AwgPort int    `json:"awg_port"`
			Mtu     int    `json:"mtu"`
		}
		if !decode(w, r, &req) {
			return
		}
		out, script, err := client.DonorManual(r.Context(), req.Host, req.AwgPort, req.Mtu)
		if err != nil {
			writeCLIError(w, "donor_manual_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"output": out,
			"script": script,
		}})
	}))

	mux.Handle("GET /api/donor/manual-script", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		script, err := client.DonorManualScript(r.Context())
		if err != nil {
			writeCLIError(w, "donor_manual_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"script": script}})
	}))

	mux.Handle("POST /api/donor/finish", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Key                          string `json:"key"`
			AllowDisableDefaultUpstreams bool   `json:"allow_disable_default_upstreams"`
		}
		if !decode(w, r, &req) {
			return
		}
		if err := mtproxylctl.ValidateDonorKey(req.Key); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_key", err.Error())
			return
		}
		start(w, "donor:finish", func(ctx context.Context) (string, error) {
			return client.DonorFinish(ctx, req.Key, req.AllowDisableDefaultUpstreams)
		})
	}))

	mux.Handle("POST /api/donor/check", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		st, err := client.DonorCheck(r.Context())
		if err != nil {
			writeCLIError(w, "donor_check_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"supported": true,
			"status":    st,
		}})
	}))

	mux.Handle("POST /api/donor/enable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			AllowDisableDefaultUpstreams bool `json:"allow_disable_default_upstreams"`
		}
		if !decode(w, r, &req) {
			return
		}
		allow := req.AllowDisableDefaultUpstreams
		start(w, "donor:on", func(ctx context.Context) (string, error) {
			return client.DonorEnable(ctx, allow)
		})
	}))

	mux.Handle("POST /api/donor/disable", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		start(w, "donor:off", client.DonorDisable)
	}))

	mux.Handle("POST /api/donor/remove", protected(func(w http.ResponseWriter, r *http.Request) {
		if !guard(w) {
			return
		}
		var req struct {
			Remote   bool   `json:"remote"`
			Password string `json:"password"`
		}
		if !decode(w, r, &req) {
			return
		}
		start(w, "donor:remove", func(ctx context.Context) (string, error) {
			return client.DonorRemove(ctx, req.Remote, req.Password)
		})
	}))
}
