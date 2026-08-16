package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// registerAvailabilityRoutes wires «Доступность из России». The check itself
// lives in MTProxyL: the telegram bot and a systemd timer need the same verdict,
// and one that only exists while the panel runs disappears with the browser tab.
// Everything here reshapes what the script already knows.
func (s *Server) registerAvailabilityRoutes(mux *http.ServeMux, jwtSecret []byte, client *mtproxylctl.Client) {
	protected := func(h http.HandlerFunc) http.Handler {
		return auth.RequireAuth(jwtSecret, h)
	}

	// Краткий статус — его опрашивает индикатор на дашборде.
	mux.Handle("GET /api/availability/status", protected(func(w http.ResponseWriter, r *http.Request) {
		st, err := client.AvailabilityStatus(r.Context())
		if err != nil {
			writeAvailabilityUnavailable(w, err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: availabilityEnvelope(st, map[string]any{
			"status": rawOrNil(st.Result),
		})})
	}))

	// Полный результат со списком зондов — страница «Доступность».
	mux.Handle("GET /api/availability/details", protected(func(w http.ResponseWriter, r *http.Request) {
		st, err := client.AvailabilityDetails(r.Context())
		if err != nil {
			writeAvailabilityUnavailable(w, err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: availabilityEnvelope(st, map[string]any{
			"result": rawOrNil(st.Result),
		})})
	}))

	// Что проверяем. GET отдаёт и заданное руками, и то, что вышло бы само —
	// без второго форма не может показать, от чего оператор отступает.
	mux.Handle("GET /api/availability/target", protected(func(w http.ResponseWriter, r *http.Request) {
		st, err := client.AvailabilityStatus(r.Context())
		if err != nil {
			writeAvailabilityUnavailable(w, err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: availabilityTargetPayload(st)})
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

		// Цель — обычные настройки MTProxyL, и меняются они той же командой,
		// что и всё остальное: своей ветки прав в sudoers для них не нужно.
		port := ""
		if ov.Port != 0 {
			port = strconv.Itoa(int(ov.Port))
		}
		for _, kv := range [][2]string{
			{"AVAILABILITY_HOST", ov.Host},
			{"AVAILABILITY_PORT", port},
			{"AVAILABILITY_SNI", ov.SNI},
		} {
			if _, err := client.SetSetting(r.Context(), kv[0], kv[1]); err != nil {
				writeCLIError(w, "availability_target_failed", err)
				return
			}
		}

		st, err := client.AvailabilityStatus(r.Context())
		if err != nil {
			writeAvailabilityUnavailable(w, err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: availabilityTargetPayload(st)})
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
		if err := client.AvailabilitySetAutoCheck(r.Context(), *body.Enabled); err != nil {
			writeCLIError(w, "availability_autocheck_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"auto_check": *body.Enabled,
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
		if err := client.AvailabilitySetToken(r.Context(), tok); err != nil {
			writeCLIError(w, "availability_token_failed", err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"has_token": tok != "",
		}})
	}))

	mux.Handle("POST /api/availability/check", protected(func(w http.ResponseWriter, r *http.Request) {
		result, err := client.AvailabilityCheck(r.Context())
		if err != nil {
			var rejected *mtproxylctl.CheckRejected
			if errors.As(err, &rejected) {
				// Отказ по квоте или частоте — не ошибка сервера, а просьба
				// подождать.
				writeError(w, http.StatusTooManyRequests, "check_rejected", rejected.Message)
				return
			}
			writeAvailabilityUnavailable(w, err)
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled": true,
			"result":  json.RawMessage(result),
		}})
	}))
}

// availabilityEnvelope adds the schedule: period, probes and threshold are the
// operator's own settings, not panel constants.
func availabilityEnvelope(st *mtproxylctl.AvailabilityState, extra map[string]any) map[string]any {
	out := map[string]any{
		"enabled":      true,
		"quota":        rawOrNil(st.Quota),
		"auto_check":   st.AutoCheck,
		"timer_active": st.TimerActive,
		"interval":     st.Interval,
		"probes":       st.Probes,
		"threshold":    st.Threshold,
		"next_run":     st.NextRun,
		"message":      st.Message,
	}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

// availabilityTargetPayload splits what the script reports into the shape the
// form needs: what the operator pinned, and what the next check will use.
func availabilityTargetPayload(st *mtproxylctl.AvailabilityState) map[string]any {
	resolved := map[string]any{
		"host": st.Target.Host,
		"port": st.Target.Port,
		"sni":  st.Target.SNI,
	}
	if st.Target.Host == "" {
		resolved["error"] = "не удалось определить адрес сервера — задайте его вручную"
	}
	return map[string]any{
		"override": map[string]any{
			"host": st.Target.Override.Host,
			"port": st.Target.OverridePort(),
			"sni":  st.Target.Override.SNI,
		},
		"resolved": resolved,
	}
}

// rawOrNil keeps an absent result absent: the page distinguishes «проверок ещё
// не было» from a verdict, and an empty object would read as the latter.
func rawOrNil(raw json.RawMessage) any {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	return raw
}

// writeAvailabilityUnavailable answers when the check cannot be reached at all:
// bridge switched off in the panel config, or an MTProxyL older than it.
func writeAvailabilityUnavailable(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, mtproxylctl.ErrDisabled):
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled": false,
			"message": "Интеграция с MTProxyL отключена в конфигурации панели",
		}})
	case errors.Is(err, mtproxylctl.ErrAvailabilityUnsupported):
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"enabled": false,
			"message": "Установленный MTProxyL не умеет проверять доступность — обновите его: mtproxyl update",
		}})
	default:
		writeCLIError(w, "availability_failed", err)
	}
}

// Формат токена dash.globalping.io. Проверяем форму, а не подлинность:
// негодный отсеется первым же ответом сервиса.
var globalpingTokenRe = regexp.MustCompile(`^[A-Za-z0-9_-]{20,200}$`)

// AvailabilityOverride is what the operator typed on the «Доступность» page.
// Autodetection is blind to a proxy behind a CDN, a second domain or a
// forwarded port. An empty field means «determine automatically».
type AvailabilityOverride struct {
	Host string `json:"host,omitempty"`
	Port uint16 `json:"port,omitempty"`
	SNI  string `json:"sni,omitempty"`
}

// hostPattern is a conservative hostname: labels of letters, digits and
// hyphens. Anything with a scheme, a slash, a colon or a space is a mistake
// worth reporting rather than passing on to the probe service.
var hostPattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$`)

// validateAvailabilityOverride rejects input that could only produce a
// confusing check result. Empty fields are valid — they mean «auto».
func validateAvailabilityOverride(o *AvailabilityOverride) error {
	o.Host = strings.TrimSpace(o.Host)
	o.SNI = strings.TrimSpace(o.SNI)

	if err := validateHostField(o.Host, "Адрес"); err != nil {
		return err
	}
	if err := validateHostField(o.SNI, "SNI"); err != nil {
		return err
	}
	return nil
}

func validateHostField(v, label string) error {
	if v == "" {
		return nil
	}
	if len(v) > 253 {
		return fmt.Errorf("%s: слишком длинное имя", label)
	}
	// IP-литерал — законная цель: у сервера может не быть домена вовсе.
	if net.ParseIP(v) != nil {
		return nil
	}
	if strings.Contains(v, "://") || strings.ContainsAny(v, "/ :?#@") {
		return fmt.Errorf("%s: нужно только имя хоста или IP, без схемы, порта и пути", label)
	}
	if !hostPattern.MatchString(v) {
		return fmt.Errorf("%s: %q не похоже на домен или IP", label, v)
	}
	return nil
}
