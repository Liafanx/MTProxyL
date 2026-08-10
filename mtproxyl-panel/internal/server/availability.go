package server

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerAvailabilityRoutes wires «Доступность из России». The check is
// outbound HTTP and needs no root; only asking MTProxyL what to check is
// privileged, and that goes through the usual sudo-whitelisted CLI.
func (s *Server) registerAvailabilityRoutes(mux *http.ServeMux, jwtSecret []byte, client *mtproxylctl.Client) {
	protected := func(h http.HandlerFunc) http.Handler {
		return auth.RequireAuth(jwtSecret, h)
	}

	s.availabilityOverride = newAvailabilityOverrideStore(s.cfg.DataDir)

	enabled := s.cfg.Globalping.GlobalpingEnabled()
	if enabled {
		s.availability = globalping.NewChecker(
			s.effectiveGlobalpingToken(),
			s.availabilityTarget(client),
			s.cfg.Globalping.Interval(),
			s.cfg.Globalping.EffectiveProbeLimit(),
		)
		s.availability.SetAutoCheck(s.availabilityOverride.autoCheckEnabled)
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
			"enabled":    true,
			"status":     st,
			"quota":      s.availability.Quota(),
			"auto_check": s.availabilityOverride.autoCheckEnabled(),
			"message":    pendingMessage(st == nil),
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
			"enabled":    true,
			"result":     res,
			"quota":      s.availability.Quota(),
			"auto_check": s.availabilityOverride.autoCheckEnabled(),
			"message":    pendingMessage(res == nil),
		}})
	}))

	// Что проверяем. GET отдаёт и заданное руками, и то, что вышло бы само —
	// без второго форма не может показать, от чего оператор отступает.
	mux.Handle("GET /api/availability/target", protected(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"override": s.availabilityOverride.public(),
			"resolved": s.resolvedAvailabilityTarget(r.Context(), client),
		}})
	}))

	mux.Handle("PUT /api/availability/target", protected(func(w http.ResponseWriter, r *http.Request) {
		var ov AvailabilityOverride
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&ov); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}
		if err := validateAvailabilityOverride(&ov); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_target", err.Error())
			return
		}
		if err := s.availabilityOverride.set(ov); err != nil {
			log.Printf("[globalping] не удалось сохранить цель проверки: %s", err)
			writeError(w, http.StatusInternalServerError, "save_failed",
				"Цель принята, но сохранить её не удалось — после перезапуска панели вернётся автоопределение")
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"override": s.availabilityOverride.public(),
			"resolved": s.resolvedAvailabilityTarget(r.Context(), client),
		}})
	}))

	// Автопроверка. Выключенная не отменяет кнопку «Проверить сейчас»: она
	// нужна тем, кто хочет проверять руками и не тратить квоту по расписанию.
	mux.Handle("PUT /api/availability/autocheck", protected(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Enabled *bool `json:"enabled"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&body); err != nil || body.Enabled == nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Ожидается {\"enabled\": true|false}")
			return
		}
		if err := s.availabilityOverride.setAutoCheck(*body.Enabled); err != nil {
			log.Printf("[globalping] не удалось сохранить автопроверку: %s", err)
			writeError(w, http.StatusInternalServerError, "save_failed",
				"Настройка принята, но сохранить её не удалось — после перезапуска панели вернётся прежняя")
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"auto_check": s.availabilityOverride.autoCheckEnabled(),
		}})
	}))

	// Токен Globalping. Наружу не отдаём — только признак, что он задан:
	// секрету незачем ездить в браузер на каждую загрузку страницы.
	mux.Handle("PUT /api/availability/token", protected(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Token *string `json:"token"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil || body.Token == nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Ожидается {\"token\": \"...\"}")
			return
		}
		tok := strings.TrimSpace(*body.Token)
		if tok != "" && !globalpingTokenRe.MatchString(tok) {
			writeError(w, http.StatusBadRequest, "invalid_token",
				"Токен Globalping — 20-200 символов из латиницы, цифр, дефиса и подчёркивания")
			return
		}
		if err := s.availabilityOverride.setAPIToken(tok); err != nil {
			log.Printf("[globalping] не удалось сохранить токен: %s", err)
			writeError(w, http.StatusInternalServerError, "save_failed",
				"Токен принят, но сохранить его не удалось — после перезапуска панели вернётся прежний")
			return
		}
		if s.availability != nil {
			s.availability.SetToken(s.effectiveGlobalpingToken())
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"has_token": s.effectiveGlobalpingToken() != "",
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

// Токен Globalping: заданный в панели важнее конфига — его меняют на ходу,
// а конфиг правят руками и реже.
func (s *Server) effectiveGlobalpingToken() string {
	if t := s.availabilityOverride.apiToken(); t != "" {
		return t
	}
	return s.cfg.Globalping.APIToken
}

// Формат токена dash.globalping.io. Проверяем форму, а не подлинность:
// негодный отсеется первым же ответом сервиса.
var globalpingTokenRe = regexp.MustCompile(`^[A-Za-z0-9_-]{20,200}$`)

// resolvedAvailabilityTarget is what the next check will use: the override where
// set, autodetection where not. The form shows it as the placeholder.
func (s *Server) resolvedAvailabilityTarget(ctx context.Context, client *mtproxylctl.Client) map[string]any {
	// Определение цели дёргает CLI и, в крайнем случае, внешний сервис за
	// адресом — на открытии страницы это не должно висеть.
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	t, err := s.availabilityTarget(client)(ctx)
	out := map[string]any{"host": t.Host, "port": t.Port, "sni": t.SNI}
	if err != nil {
		out["error"] = err.Error()
	}
	return out
}

func pendingMessage(empty bool) string {
	if empty {
		return "Проверки ещё не проводились"
	}
	return ""
}

// availabilityTarget answers what to check: address, proxy port and the FakeTLS
// domain for SNI. Re-read before every check — the operator changes them here.
func (s *Server) availabilityTarget(client *mtproxylctl.Client) globalping.TargetProvider {
	return func(ctx context.Context) (globalping.Target, error) {
		var t globalping.Target

		// Указанное руками важнее всего остального, включая override_host из
		// конфига: это ответ оператора на вопрос «а что, собственно, проверять»,
		// и автоопределение он уже видел — форма показывает его как подсказку.
		ov := s.availabilityOverride.get()
		t.Host, t.Port, t.SNI = ov.Host, ov.Port, ov.SNI
		if t.Host != "" && t.Port != 0 && t.SNI != "" {
			return t, nil
		}

		// Порт и fake SNI знает MTProxyL, для текущего режима: у реаниматора они
		// живут в конфиге чужой цели. Подставляем только незаданные руками поля.
		if client.Enabled() && (t.Port == 0 || t.SNI == "") {
			if st, err := client.GetMode(ctx); err == nil {
				if t.Port == 0 && st.Port > 0 && st.Port <= 65535 {
					t.Port = uint16(st.Port)
				}
				if t.SNI == "" {
					t.SNI = st.SNI
				}
			} else {
				log.Printf("[globalping] не удалось спросить режим у MTProxyL: %s", err)
			}
		}

		// Адрес: явное указание в конфиге важнее автоопределения — им чинят
		// случаи, где сервер сам себя определяет не так, как видят клиенты.
		if h := strings.TrimSpace(s.cfg.Globalping.OverrideHost); t.Host == "" && h != "" {
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

// settingsFallback reads MTProxyL's settings.conf directly — only a fallback,
// the CLI knows better in reanimator mode. The file is world-readable by
// design, but an older MTProxyL alongside can still deny it: hence empty
// result rather than a failed check.
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
