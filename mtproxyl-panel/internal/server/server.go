package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/acme/autocert"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/auto_update"
	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
	"github.com/Liafanx/mtproxyl-panel/internal/logs"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
	"github.com/Liafanx/mtproxyl-panel/internal/panel_updater"
	"github.com/Liafanx/mtproxyl-panel/internal/proxy"
	"github.com/Liafanx/mtproxyl-panel/internal/spa"
	"github.com/Liafanx/mtproxyl-panel/internal/telemt_config"
	"github.com/Liafanx/mtproxyl-panel/internal/updater"
	"github.com/Liafanx/mtproxyl-panel/internal/ws"
)

// loginRateLimiter tracks failed login attempts per IP.
type loginRateLimiter struct {
	mu       sync.Mutex
	attempts map[string][]time.Time
}

func newLoginRateLimiter() *loginRateLimiter {
	rl := &loginRateLimiter{attempts: make(map[string][]time.Time)}
	go rl.cleanup()
	return rl
}

// cleanup periodically removes stale entries to prevent unbounded memory growth.
func (rl *loginRateLimiter) cleanup() {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		rl.mu.Lock()
		now := time.Now()
		for ip, times := range rl.attempts {
			valid := times[:0]
			for _, t := range times {
				if now.Sub(t) < 5*time.Minute {
					valid = append(valid, t)
				}
			}
			if len(valid) == 0 {
				delete(rl.attempts, ip)
			} else {
				rl.attempts[ip] = valid
			}
		}
		rl.mu.Unlock()
	}
}

// allow returns true if the IP has fewer than maxAttempts in the given window.
func (rl *loginRateLimiter) allow(ip string, maxAttempts int, window time.Duration) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-window)

	// Remove expired entries
	valid := rl.attempts[ip][:0]
	for _, t := range rl.attempts[ip] {
		if t.After(cutoff) {
			valid = append(valid, t)
		}
	}
	rl.attempts[ip] = valid

	return len(valid) < maxAttempts
}

// record adds a failed attempt for the IP.
func (rl *loginRateLimiter) record(ip string) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rl.attempts[ip] = append(rl.attempts[ip], time.Now())
}

type Server struct {
	cfg *config.Config
	// availability is the «Доступность из России» checker; nil when it is
	// turned off in the config.
	availability *globalping.Checker
	// availabilityOverride is the operator's answer to what should be checked.
	availabilityOverride *availabilityOverrideStore
}

func New(cfg *config.Config) *Server {
	return &Server{cfg: cfg}
}

type jsonResponse struct {
	OK   bool        `json:"ok"`
	Data interface{} `json:"data,omitempty"`
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("json encode error: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"ok": false,
		"error": map[string]string{
			"code":    code,
			"message": message,
		},
	})
}

func (s *Server) Run(version string, distFS fs.FS) error {
	jwtSecret := []byte(s.cfg.Auth.JWTSecret)

	ttl, err := time.ParseDuration(s.cfg.Auth.SessionTTL)
	if err != nil {
		ttl = 24 * time.Hour
	}

	telemtProxy, err := proxy.NewTelemtProxy(s.cfg.Telemt.URL, s.cfg.Telemt.AuthHeader)
	if err != nil {
		return err
	}

	limiter := newLoginRateLimiter()
	mux := http.NewServeMux()

	// Auth endpoints
	mux.HandleFunc("POST /api/auth/login", func(w http.ResponseWriter, r *http.Request) {
		ip := r.RemoteAddr
		// Strip port from RemoteAddr (e.g. "1.2.3.4:12345" → "1.2.3.4")
		if host, _, ok := strings.Cut(ip, ":"); ok {
			ip = host
		}
		// Use only the first (leftmost, client) IP from X-Forwarded-For
		if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
			if first, _, _ := strings.Cut(fwd, ","); first != "" {
				ip = strings.TrimSpace(first)
			}
		}

		if !limiter.allow(ip, 5, 1*time.Minute) {
			writeError(w, http.StatusTooManyRequests, "rate_limited", "Слишком много попыток входа, повторите позже")
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB limit
		var req loginRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}

		if req.Username != s.cfg.Auth.Username || !auth.CheckPassword(req.Password, s.cfg.Auth.PasswordHash) {
			limiter.record(ip)
			writeError(w, http.StatusUnauthorized, "unauthorized", "Неверный логин или пароль")
			return
		}

		token, err := auth.GenerateToken(req.Username, jwtSecret, ttl)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", "Не удалось создать токен сессии")
			return
		}

		cookiePath := "/"
		if s.cfg.BasePath != "" {
			cookiePath = s.cfg.BasePath + "/"
		}
		http.SetCookie(w, &http.Cookie{
			Name:     "session",
			Value:    token,
			Path:     cookiePath,
			MaxAge:   int(ttl.Seconds()),
			HttpOnly: true,
			SameSite: http.SameSiteStrictMode,
			Secure:   r.TLS != nil,
		})

		writeJSON(w, http.StatusOK, jsonResponse{
			OK:   true,
			Data: map[string]string{"username": req.Username},
		})
	})

	mux.HandleFunc("POST /api/auth/logout", func(w http.ResponseWriter, r *http.Request) {
		cookiePath := "/"
		if s.cfg.BasePath != "" {
			cookiePath = s.cfg.BasePath + "/"
		}
		http.SetCookie(w, &http.Cookie{
			Name:     "session",
			Value:    "",
			Path:     cookiePath,
			MaxAge:   -1,
			HttpOnly: true,
			SameSite: http.SameSiteStrictMode,
		})
		writeJSON(w, http.StatusOK, jsonResponse{OK: true})
	})

	mux.Handle("GET /api/auth/me", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{
			OK:   true,
			Data: map[string]string{"username": r.Header.Get("X-Auth-User")},
		})
	})))

	// User defaults endpoint
	mux.Handle("GET /api/users/defaults", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: s.cfg.Users})
	})))

	// WebSocket endpoint (auth checked via cookie on upgrade)
	wsHandler := ws.NewHandler(s.cfg.Telemt.URL, s.cfg.Telemt.AuthHeader)
	mux.Handle("/api/ws", auth.RequireAuth(jwtSecret, wsHandler))

	// Update endpoints
	upd := updater.New(
		s.cfg.Telemt.URL,
		s.cfg.Telemt.BinaryPath,
		s.cfg.Telemt.ServiceName,
		s.cfg.Telemt.GithubRepo,
		s.cfg.Telemt.AuthHeader,
		s.cfg.DataDir,
		s.cfg.Panel.MaxNewerReleases,
		s.cfg.Panel.MaxOlderReleases,
		s.cfg.Panel.GithubToken,
	)

	mux.Handle("GET /api/update/check", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result, err := upd.Check()
		if err != nil {
			writeError(w, http.StatusBadGateway, "update_check_failed", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	})))

	mux.Handle("GET /api/update/releases", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result, err := upd.Releases()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "RELEASES_ERROR", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	})))

	mux.Handle("POST /api/update/apply", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Version string `json:"version"`
		}
		// Body is optional — ignore decode errors for backward compat
		_ = json.NewDecoder(r.Body).Decode(&req)

		if err := upd.Apply(req.Version); err != nil {
			writeError(w, http.StatusConflict, "UPDATE_IN_PROGRESS", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: upd.GetStatus()})
	})))

	mux.Handle("GET /api/update/status", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: upd.GetStatus()})
	})))

	// Panel update endpoints
	panelUpd := panel_updater.New(
		version,
		s.cfg.Panel.BinaryPath,
		s.cfg.Panel.ServiceName,
		s.cfg.Panel.GithubRepo,
		s.cfg.DataDir,
		s.cfg.Panel.MaxNewerReleases,
		s.cfg.Panel.MaxOlderReleases,
		s.cfg.Panel.GithubToken,
	)

	mux.Handle("GET /api/panel/update/check", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result, err := panelUpd.Check()
		if err != nil {
			writeError(w, http.StatusBadGateway, "update_check_failed", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	})))

	mux.Handle("GET /api/panel/update/releases", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result, err := panelUpd.Releases()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "RELEASES_ERROR", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	})))

	mux.Handle("POST /api/panel/update/apply", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Version string `json:"version"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)

		if err := panelUpd.Apply(req.Version); err != nil {
			writeError(w, http.StatusConflict, "UPDATE_IN_PROGRESS", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: panelUpd.GetStatus()})
	})))

	mux.Handle("GET /api/panel/update/status", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: panelUpd.GetStatus()})
	})))

	// Auto-update manager
	autoMgr := auto_update.New()
	autoMgr.Register("panel", auto_update.Component{
		CheckFn: func() (*auto_update.CheckResult, error) {
			r, err := panelUpd.Check()
			if err != nil {
				return nil, err
			}
			return &auto_update.CheckResult{
				CurrentVersion:  r.CurrentVersion,
				LatestVersion:   r.LatestVersion,
				UpdateAvailable: r.UpdateAvailable,
				ReleaseName:     r.ReleaseName,
				ReleaseURL:      r.ReleaseURL,
				PublishedAt:     r.PublishedAt,
				Changelog:       r.Changelog,
			}, nil
		},
		ApplyFn: func(version string) error { return panelUpd.Apply(version) },
	}, auto_update.ComponentConfig{
		Enabled:       s.cfg.Panel.AutoUpdate.Enabled,
		CheckInterval: s.cfg.Panel.AutoUpdate.CheckInterval,
		AutoApply:     s.cfg.Panel.AutoUpdate.AutoApply,
	})
	autoMgr.Register("telemt", auto_update.Component{
		CheckFn: func() (*auto_update.CheckResult, error) {
			r, err := upd.Check()
			if err != nil {
				return nil, err
			}
			return &auto_update.CheckResult{
				CurrentVersion:  r.CurrentVersion,
				LatestVersion:   r.LatestVersion,
				UpdateAvailable: r.UpdateAvailable,
				ReleaseName:     r.ReleaseName,
				ReleaseURL:      r.ReleaseURL,
				PublishedAt:     r.PublishedAt,
				Changelog:       r.Changelog,
			}, nil
		},
		ApplyFn: func(version string) error { return upd.Apply(version) },
	}, auto_update.ComponentConfig{
		Enabled:       s.cfg.Telemt.AutoUpdate.Enabled,
		CheckInterval: s.cfg.Telemt.AutoUpdate.CheckInterval,
		AutoApply:     s.cfg.Telemt.AutoUpdate.AutoApply,
	})
	defer autoMgr.StopAll()

	// Auto-update API
	mux.Handle("GET /api/auto-update/status", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: autoMgr.GetStatus()})
	})))
	mux.Handle("PUT /api/auto-update/config", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req auto_update.UpdateConfigRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}
		autoMgr.UpdateConfig("panel", req.Panel)
		autoMgr.UpdateConfig("telemt", req.Telemt)

		// Persist auto-update settings to config file
		if s.cfg.Path != "" {
			updates := map[string]interface{}{
				"panel.auto_update.enabled":         req.Panel.Enabled,
				"panel.auto_update.check_interval":  req.Panel.CheckInterval,
				"panel.auto_update.auto_apply":      req.Panel.AutoApply,
				"telemt.auto_update.enabled":        req.Telemt.Enabled,
				"telemt.auto_update.check_interval": req.Telemt.CheckInterval,
				"telemt.auto_update.auto_apply":     req.Telemt.AutoApply,
			}
			if _, err := telemt_config.QuickUpdate(s.cfg.Path, updates); err != nil {
				log.Printf("WARNING: failed to persist auto-update config: %s", err)
			}
		}

		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: autoMgr.GetStatus()})
	})))

	// MTProxyL host-level endpoints (mode, selfmask, backups)
	s.registerMtproxylRoutes(mux, jwtSecret)

	// Доступность прокси из России глазами обычных пользователей
	s.registerAvailabilityRoutes(mux, jwtSecret, mtproxylctl.New(s.cfg.Mtproxyl))

	// Telemt service restart endpoint
	mux.Handle("POST /api/telemt/restart", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := updater.RestartService(s.cfg.Telemt.ServiceName); err != nil {
			writeError(w, http.StatusInternalServerError, "restart_failed", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]string{"status": "restarting"}})
	})))

	// Один клиент MTProxyL на маршруты конфига: по нему определяется, не
	// обслуживаем ли мы сейчас чужую цель, конфиг которой править через API
	// нельзя.
	mtproxylForConfig := mtproxylctl.New(s.cfg.Mtproxyl)

	// Helper: resolve Telemt config path from panel config or Telemt API
	getTelemtConfigPath := func(w http.ResponseWriter) (string, bool) {
		if s.cfg.Telemt.ConfigPath != "" {
			return s.cfg.Telemt.ConfigPath, true
		}
		systemInfo, err := telemtProxy.GetSystemInfo()
		if err != nil {
			writeError(w, http.StatusBadGateway, "telemt_api_error", err.Error())
			return "", false
		}
		return systemInfo.ConfigPath, true
	}

	// Telemt config endpoints
	mux.Handle("GET /api/telemt/config/raw", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		target := resolveConfigEditTarget(r.Context(), s.cfg.Telemt, mtproxylForConfig)

		if target.Mode == "api" {
			sections, revision, err := telemtProxy.GetManagedConfig()
			if err != nil {
				writeError(w, http.StatusBadGateway, "telemt_api_error", err.Error())
				return
			}
			content, err := telemt_config.SectionsToTOML(sections)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "render_failed", err.Error())
				return
			}
			writeJSON(w, http.StatusOK, jsonResponse{
				OK: true,
				Data: map[string]string{
					"content": content,
					"path":    "telemt://v1/config",
					"hash":    revision,
					"mode":    "api",
				},
			})
			return
		}

		// file mode
		configPath := target.Path
		if configPath == "" {
			var ok bool
			if configPath, ok = getTelemtConfigPath(w); !ok {
				return
			}
		}
		var content, hash string
		if target.Reanimator {
			raw, err := mtproxylForConfig.TargetConfigShow(r.Context())
			if err != nil {
				writeCLIError(w, "read_config_failed", err)
				return
			}
			content, hash = raw, telemt_config.Hash(raw)
		} else {
			var err error
			if content, hash, err = telemt_config.ReadConfig(configPath); err != nil {
				writeError(w, http.StatusInternalServerError, "read_config_failed", err.Error())
				return
			}
		}
		data := map[string]string{
			"content": content,
			"path":    configPath,
			"hash":    hash,
			"mode":    "file",
		}
		if target.Reanimator {
			// Панель показывает это как причину, почему баннер про заводские
			// значения не появился и правится именно файл.
			data["mode_reason"] = "reanimator"
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: data})
	})))

	mux.Handle("POST /api/telemt/config/save", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Content string `json:"content"`
			Hash    string `json:"hash"`
			Restart bool   `json:"restart"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}

		target := resolveConfigEditTarget(r.Context(), s.cfg.Telemt, mtproxylForConfig)

		if target.Mode == "api" {
			sections, err := telemt_config.TOMLToSections(req.Content)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_toml", err.Error())
				return
			}
			// Отправляем только изменённые секции. Редактор заполняется
			// действующей конфигурацией движка — со всеми заводскими
			// значениями, — и отправка её целиком записала бы эти значения в
			// файл явно, зафиксировав их на сегодняшнем уровне.
			if current, _, err := telemtProxy.GetManagedConfig(); err == nil {
				sections = telemt_config.ChangedSections(sections, current)
				if len(sections) == 0 {
					writeJSON(w, http.StatusOK, jsonResponse{
						OK: true,
						Data: map[string]interface{}{
							"success": true, "new_hash": req.Hash, "changed": false,
						},
					})
					return
				}
			} else {
				// Не смогли прочитать текущее состояние — отправляем как есть:
				// потерять правку хуже, чем записать лишние значения.
				log.Printf("[config] не удалось прочитать текущий конфиг для сравнения: %s", err)
			}
			res, err := telemtProxy.PatchManagedConfig(sections, req.Hash)
			if err != nil {
				var apiErr *proxy.TelemtAPIError
				if errors.As(err, &apiErr) {
					writeError(w, apiErr.Status, apiErr.Code, apiErr.Message)
					return
				}
				writeError(w, http.StatusBadGateway, "telemt_api_error", err.Error())
				return
			}
			if req.Restart || res.RestartRequired {
				if err := updater.RestartService(s.cfg.Telemt.ServiceName); err != nil {
					writeError(w, http.StatusInternalServerError, "restart_failed", err.Error())
					return
				}
			}
			writeJSON(w, http.StatusOK, jsonResponse{
				OK: true,
				Data: map[string]interface{}{
					"success":          true,
					"new_hash":         res.Revision,
					"restart_required": res.RestartRequired,
					"changed":          res.Changed,
				},
			})
			return
		}

		// file mode
		if target.Reanimator {
			// Перезапуск тоже за MTProxyL: цель может быть контейнером или
			// юнитом, а панель настроена на имя службы своего движка.
			if _, err := mtproxylForConfig.TargetConfigWrite(r.Context(), req.Content, req.Restart); err != nil {
				writeCLIError(w, "save_failed", err)
				return
			}
			writeJSON(w, http.StatusOK, jsonResponse{
				OK:   true,
				Data: map[string]interface{}{"success": true, "new_hash": telemt_config.Hash(req.Content)},
			})
			return
		}

		configPath := target.Path
		if configPath == "" {
			var ok bool
			if configPath, ok = getTelemtConfigPath(w); !ok {
				return
			}
		}
		backupDir := filepath.Join(os.TempDir(), "mtproxyl-panel-config-backups")
		if s.cfg.DataDir != "" {
			backupDir = filepath.Join(s.cfg.DataDir, "config-backups")
		}
		if err := telemt_config.SaveConfigFile(configPath, req.Content, backupDir); err != nil {
			writeError(w, http.StatusBadRequest, "save_failed", err.Error())
			return
		}
		newHash := telemt_config.Hash(req.Content)
		if req.Restart {
			if err := updater.RestartService(s.cfg.Telemt.ServiceName); err != nil {
				writeError(w, http.StatusInternalServerError, "restart_failed", err.Error())
				return
			}
		}
		writeJSON(w, http.StatusOK, jsonResponse{
			OK:   true,
			Data: map[string]interface{}{"success": true, "new_hash": newHash},
		})
	})))

	// GeoIP lookup endpoint. The database is resolved lazily (see
	// getGeoIPLookup below) so a database installed later from the panel's
	// Addons page — or by a system package after the panel started — is
	// picked up on the next lookup without a restart.
	if s.cfg.GeoIP.DBPath == "" {
		// Молчание здесь читалось как «всё в порядке», а в интерфейсе при этом
		// появлялось предупреждение о недоступном GeoIP.
		log.Printf("GeoIP: база не найдена — адреса будут показаны без страны и провайдера; " +
			"установите её из панели (Дополнения) или положите GeoLite2-City.mmdb в data_dir")
	}

	mux.Handle("POST /api/geoip/lookup", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lookup := getGeoIPLookup(s.cfg)
		if lookup == nil {
			writeError(w, http.StatusServiceUnavailable, "geoip_disabled", "GeoIP database is not configured")
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		var req struct {
			IPs []string `json:"ips"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}

		if len(req.IPs) > 2000 {
			writeError(w, http.StatusBadRequest, "too_many_ips", "maximum 2000 IPs per request")
			return
		}

		results := lookup.LookupIPs(req.IPs)
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: results})
	})))

	// Logs
	//
	// Источник определяется на каждое подключение, а не один раз при старте:
	// какой движок логировать, зависит от текущего режима MTProxyL, а он
	// меняется на ходу. Раньше панель до перезапуска держала контейнер,
	// записанный при установке, и после ухода в реаниматор читала логи
	// несуществующего контейнера.
	logTarget := func() (service, container string) {
		service, container = s.cfg.Telemt.ServiceName, s.cfg.Telemt.ContainerName
		if !mtproxylForConfig.Enabled() {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		st, err := cachedMode(ctx, mtproxylForConfig)
		if err != nil || st == nil || st.LogTarget == "" {
			return
		}
		switch st.LogKind {
		case "docker":
			return "", st.LogTarget
		case "service":
			return st.LogTarget, ""
		}
		return
	}

	mux.Handle("GET /api/logs/status", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		service, container := logTarget()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: logs.CheckStatus(service, container)})
	})))

	logsWsHandler := logs.NewDynamicWsHandler(func() (logs.LogSource, error) {
		service, container := logTarget()
		return logs.DetectSource(service, container)
	}, 2)
	mux.Handle("/api/ws/logs", auth.RequireAuth(jwtSecret, logsWsHandler))

	// Telemt connectivity check (diagnostic endpoint)
	mux.Handle("GET /api/telemt/connectivity", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := telemtProxy.ConnectivityCheck()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: result})
	})))

	// Telemt API proxy (kept for direct REST calls like user CRUD)
	mux.Handle("/api/telemt/", auth.RequireAuth(jwtSecret, telemtProxy))

	// SPA
	mux.Handle("/", spa.NewHandler(distFS, s.cfg.BasePath))

	// Build handler chain: securityHeaders → basePathHandler (if needed) → mux
	var handler http.Handler = mux
	if s.cfg.BasePath != "" {
		handler = basePathHandler(s.cfg.BasePath, mux)
	}
	handler = securityHeaders(handler)

	srv := &http.Server{
		Addr:         s.cfg.Listen,
		Handler:      handler,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// TLS: ACME (Let's Encrypt)
	if s.cfg.TLS.AcmeDomain != "" {
		manager := &autocert.Manager{
			Cache:      autocert.DirCache(s.cfg.TLS.AcmeCacheDir),
			Prompt:     autocert.AcceptTOS,
			HostPolicy: autocert.HostWhitelist(s.cfg.TLS.AcmeDomain),
		}
		srv.TLSConfig = manager.TLSConfig()

		// HTTP->HTTPS redirect on port 80
		go func() {
			log.Printf("MTProxyL-Panel HTTP->HTTPS redirect on :80")
			if err := http.ListenAndServe(":80", manager.HTTPHandler(nil)); err != nil {
				log.Printf("HTTP redirect server error: %s", err)
			}
		}()

		log.Printf("MTProxyL-Panel listening on %s (ACME TLS, domain: %s)", s.cfg.Listen, s.cfg.TLS.AcmeDomain)
		return srv.ListenAndServeTLS("", "")
	}

	// TLS: self-signed, generated on first start when the files are absent.
	// Checked before the custom-certificate branch because it uses the same
	// cert_file/key_file pair — it only fills them in.
	if s.cfg.TLS.SelfSigned && s.cfg.TLS.CertFile != "" {
		if err := ensureSelfSignedCert(
			s.cfg.TLS.CertFile, s.cfg.TLS.KeyFile, s.cfg.TLS.SelfSignedHosts,
		); err != nil {
			return fmt.Errorf("self-signed TLS: %w", err)
		}
		log.Printf("MTProxyL-Panel listening on %s (TLS, самоподписанный сертификат)", s.cfg.Listen)
		log.Printf("Браузер предупредит о недоверенном сертификате — это ожидаемо")
		return srv.ListenAndServeTLS(s.cfg.TLS.CertFile, s.cfg.TLS.KeyFile)
	}

	// TLS: custom certificates
	if s.cfg.TLS.CertFile != "" {
		log.Printf("MTProxyL-Panel listening on %s (TLS)", s.cfg.Listen)
		return srv.ListenAndServeTLS(s.cfg.TLS.CertFile, s.cfg.TLS.KeyFile)
	}

	// Plain HTTP: пароль администратора и токен сессии уходят открытым
	// текстом, поэтому это стоит сказать вслух, а не молча слушать :8080.
	log.Printf("MTProxyL-Panel listening on %s (HTTP, без шифрования)", s.cfg.Listen)
	log.Printf("ВНИМАНИЕ: пароль и токен сессии передаются открытым текстом. " +
		"Включить HTTPS: self_signed = true в секции [tls] конфига панели")
	return srv.ListenAndServe()
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		if r.TLS != nil {
			w.Header().Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		}
		next.ServeHTTP(w, r)
	})
}

// basePathHandler strips the base path prefix from incoming requests.
// GET /{basePath} → 301 redirect to /{basePath}/
// /{basePath}/... → strip prefix, pass to next handler
// anything else → 404
func basePathHandler(basePath string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Exact match without trailing slash → redirect
		if r.URL.Path == basePath {
			http.Redirect(w, r, basePath+"/", http.StatusMovedPermanently)
			return
		}

		prefix := basePath + "/"
		if !strings.HasPrefix(r.URL.Path, prefix) {
			http.NotFound(w, r)
			return
		}

		// Strip base path, keep leading slash
		r.URL.Path = "/" + strings.TrimPrefix(r.URL.Path, prefix)
		r.URL.RawPath = ""
		next.ServeHTTP(w, r)
	})
}
