package server

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerAvailabilityRoutes wires «Доступность из России».
//
// The check itself is outbound HTTP to a public probe network, so nothing here
// needs root; the only privileged bit is asking MTProxyL what to check, and
// that goes through the same sudo-whitelisted CLI as the rest of the panel.
func (s *Server) registerAvailabilityRoutes(mux *http.ServeMux, jwtSecret []byte, client *mtproxylctl.Client) {
	protected := func(h http.HandlerFunc) http.Handler {
		return auth.RequireAuth(jwtSecret, h)
	}

	enabled := s.cfg.Globalping.GlobalpingEnabled()
	if enabled {
		s.availability = globalping.NewChecker(
			s.cfg.Globalping.APIToken,
			s.availabilityTarget(client),
			s.cfg.Globalping.Interval(),
			s.cfg.Globalping.EffectiveProbeLimit(),
		)
		go s.availability.Start(context.Background())
	} else {
		log.Println("[globalping] проверка доступности выключена в конфиге панели")
	}

	// Краткий статус — его опрашивает индикатор на дашборде.
	mux.Handle("GET /api/availability/status", protected(func(w http.ResponseWriter, r *http.Request) {
		if s.availability == nil {
			writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"enabled": false}})
			return
		}
		st := s.availability.Store().GetStatus()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled": true,
			"status":  st,
			"message": pendingMessage(st == nil),
		}})
	}))

	// Полный результат со списком зондов — страница «Доступность».
	mux.Handle("GET /api/availability/details", protected(func(w http.ResponseWriter, r *http.Request) {
		if s.availability == nil {
			writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{"enabled": false}})
			return
		}
		res := s.availability.Store().Get()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled": true,
			"result":  res,
			"message": pendingMessage(res == nil),
		}})
	}))

	mux.Handle("POST /api/availability/check", protected(func(w http.ResponseWriter, r *http.Request) {
		if s.availability == nil {
			writeError(w, http.StatusBadRequest, "disabled",
				"Проверка доступности выключена: [globalping] enabled = false в конфиге панели")
			return
		}
		result, err := s.availability.RunCheckNow(r.Context())
		if err != nil {
			// Отказ по частоте — не ошибка сервера, а просьба подождать.
			writeError(w, http.StatusTooManyRequests, "check_rejected", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled": true,
			"result":  result,
		}})
	}))
}

func pendingMessage(empty bool) string {
	if empty {
		return "Проверки ещё не проводились"
	}
	return ""
}

// availabilityTarget answers what to check: the address probes connect to, the
// proxy port and the FakeTLS domain to put in SNI.
//
// Everything is re-read before each check — the operator changes the port and
// the domain from this very panel.
func (s *Server) availabilityTarget(client *mtproxylctl.Client) globalping.TargetProvider {
	return func(ctx context.Context) (globalping.Target, error) {
		var t globalping.Target

		// Порт и fake SNI знает MTProxyL, причём для текущего режима: у
		// реаниматора они живут в конфиге чужой цели, а не в settings.conf,
		// и брать их оттуда значило бы проверять рукопожатие с чужим доменом.
		if client.Enabled() {
			if st, err := client.GetMode(ctx); err == nil {
				if st.Port > 0 && st.Port <= 65535 {
					t.Port = uint16(st.Port)
				}
				t.SNI = st.SNI
			} else {
				log.Printf("[globalping] не удалось спросить режим у MTProxyL: %s", err)
			}
		}

		// Адрес: явное указание в конфиге важнее всего — им чинят случаи,
		// где сервер сам себя определяет не так, как видят клиенты.
		if h := strings.TrimSpace(s.cfg.Globalping.OverrideHost); h != "" {
			t.Host = h
		}

		// Дальше — то, что MTProxyL кладёт в ссылки: домен заглушки, если она
		// поднята, иначе прикреплённый адрес из настроек.
		fallback := s.settingsFallback()
		if t.Host == "" && client.Enabled() {
			if sm, err := client.SelfmaskStatus(ctx); err == nil && sm.Enabled && sm.Domain != "" {
				t.Host = sm.Domain
			}
		}
		if t.Host == "" {
			if v := fallback["SELFMASK_DOMAIN"]; v != "" && fallback["SELFMASK_ENABLED"] == "true" {
				t.Host = v
			}
		}
		if t.Host == "" {
			t.Host = fallback["CUSTOM_IP"]
		}
		if t.Port == 0 {
			if p, err := strconv.ParseUint(fallback["PROXY_PORT"], 10, 16); err == nil && p > 0 {
				t.Port = uint16(p)
			}
		}
		if t.SNI == "" {
			t.SNI = fallback["PROXY_DOMAIN"]
		}

		// Последнее средство — внешний адрес сервера. Он же самый честный:
		// именно на него клиенты и приходят, когда домен не задан.
		if t.Host == "" {
			ip, err := globalping.PublicIP(ctx)
			if err != nil {
				return t, fmt.Errorf("%w", err)
			}
			t.Host = ip
		}
		return t, nil
	}
}

// settingsFallback reads MTProxyL's settings.conf directly.
//
// Only a fallback: the CLI knows better in reanimator mode, where the engine's
// real port and domain live in the target's config. The file is world-readable
// by design (MTProxyL keeps its secrets in a separate 600 file), but a panel
// installed next to an older MTProxyL can still hit a permission error — hence
// the silent empty result rather than a failed check.
func (s *Server) settingsFallback() map[string]string {
	out := map[string]string{}
	if s.cfg.Mtproxyl.InstallDir == "" {
		return out
	}
	f, err := os.Open(filepath.Join(s.cfg.Mtproxyl.InstallDir, "settings.conf"))
	if err != nil {
		return out
	}
	defer func() { _ = f.Close() }()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if key != "" {
			out[key] = value
		}
	}
	return out
}
