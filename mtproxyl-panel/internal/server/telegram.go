package server

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
	"github.com/Liafanx/mtproxyl-panel/internal/tgbot"
	"github.com/Liafanx/mtproxyl-panel/internal/uplink"
)

// telegramBotFile — настройки бота и то, что ему нужно помнить между
// перезапусками. Отдельным файлом, а не в конфиге панели: тот написан руками
// и с комментариями, и переписывание его из формы стоило бы этих комментариев.
const telegramBotFile = "telegram-bot.json"

// TelegramBotConfig — то, что оператор задал в панели, плюс память бота.
//
// Указатели у настроек значат «не задано»: форма присылает только своё поле,
// и сохранение порога не должно стирать токен. Поля состояния — обычные: их
// пишет сам бот и всегда целиком.
type TelegramBotConfig struct {
	Enabled        *bool    `json:"enabled,omitempty"`
	Token          *string  `json:"token,omitempty"`
	AdminID        *int64   `json:"admin_id,omitempty"`
	AlertThreshold *float64 `json:"alert_threshold,omitempty"`

	// StatusMessageID — то самое единственное живое сообщение. Переживает
	// перезапуск панели, иначе каждый рестарт плодил бы в чате новое.
	StatusMessageID int `json:"status_message_id,omitempty"`
	// Состояние алерта: без него перезапуск посреди аварии присылал бы
	// повторный алерт, а счётчик длительности начинался бы заново.
	AlertActive    bool    `json:"alert_active,omitempty"`
	AlertSinceUnix int64   `json:"alert_since_unix,omitempty"`
	LastAlertUnix  int64   `json:"last_alert_unix,omitempty"`
	LastPercentage float64 `json:"last_percentage,omitempty"`
	HasPercentage  bool    `json:"has_percentage,omitempty"`

	// Состояние новых инцидентов — плоскими полями рядом, а не вложенной
	// структурой. При обновлении отсутствующие ключи читаются нулями, а ноль
	// здесь значит «инцидента не было», так что ложной тревоги задним числом
	// не будет. При откате на прежнюю версию она этих ключей не знает: файл не
	// бьётся, доступность продолжает работать, теряется только память о новых
	// инцидентах.
	UplinkAlertActive    bool  `json:"uplink_alert_active,omitempty"`
	UplinkAlertSinceUnix int64 `json:"uplink_alert_since_unix,omitempty"`
	UplinkLastAlertUnix  int64 `json:"uplink_last_alert_unix,omitempty"`

	EngineAlertActive    bool  `json:"engine_alert_active,omitempty"`
	EngineAlertSinceUnix int64 `json:"engine_alert_since_unix,omitempty"`
	EngineLastAlertUnix  int64 `json:"engine_last_alert_unix,omitempty"`

	// LastKnownIP — внешний адрес сервера, каким его видели в прошлый раз.
	LastKnownIP string `json:"last_known_ip,omitempty"`
	// Пауза тревог на время работ.
	MutedUntilUnix int64 `json:"muted_until_unix,omitempty"`
	MuteForever    bool  `json:"mute_forever,omitempty"`

	// ConnectFailThreshold — доля неудачных подключений к дата-центрам, выше
	// которой поднимается тревога.
	ConnectFailThreshold *float64 `json:"connect_fail_threshold,omitempty"`
}

// telegramBotStore хранит настройки бота на диске рядом с остальным, что
// панель знает о себе сама.
type telegramBotStore struct {
	mu   sync.RWMutex
	path string
	cur  TelegramBotConfig
}

func newTelegramBotStore(dataDir string) *telegramBotStore {
	s := &telegramBotStore{}
	if dataDir != "" {
		s.path = filepath.Join(dataDir, telegramBotFile)
	}
	s.load()
	return s
}

func (s *telegramBotStore) load() {
	if s.path == "" {
		return
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		return // файла нет — бот просто не настроен, это нормальный случай
	}
	var c TelegramBotConfig
	if err := json.Unmarshal(data, &c); err != nil {
		// Битый файл не должен мешать панели подняться: бот окажется
		// выключенным, а настройки вернутся первым сохранением.
		log.Printf("[tgbot] %s не разобран, настройки бота считаются пустыми: %s", s.path, err)
		return
	}
	s.mu.Lock()
	s.cur = c
	s.mu.Unlock()
}

func (s *telegramBotStore) get() TelegramBotConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cur
}

// botConfig переводит хранимое в то, чем живёт сам бот.
func (s *telegramBotStore) botConfig() tgbot.Config {
	c := s.get()
	cfg := tgbot.Config{AlertThreshold: tgbot.DefaultThreshold}
	if c.Enabled != nil {
		cfg.Enabled = *c.Enabled
	}
	if c.Token != nil {
		cfg.Token = *c.Token
	}
	if c.AdminID != nil {
		cfg.AdminID = *c.AdminID
	}
	if c.AlertThreshold != nil && *c.AlertThreshold > 0 {
		cfg.AlertThreshold = *c.AlertThreshold
	}
	return cfg
}

func (s *telegramBotStore) botState() tgbot.PersistedState {
	c := s.get()
	st := tgbot.PersistedState{
		MessageID: c.StatusMessageID,
		Incidents: tgbot.Incidents{
			Availability: tgbot.AlertState{
				Active:  c.AlertActive,
				LastPct: c.LastPercentage,
				HasPct:  c.HasPercentage,
			},
			Uplink:      tgbot.IncidentState{Active: c.UplinkAlertActive},
			Engine:      tgbot.IncidentState{Active: c.EngineAlertActive},
			LastKnownIP: c.LastKnownIP,
			MuteForever: c.MuteForever,
		},
	}
	st.Incidents.Availability.Since = fromUnix(c.AlertSinceUnix)
	st.Incidents.Availability.LastNotify = fromUnix(c.LastAlertUnix)
	st.Incidents.Uplink.Since = fromUnix(c.UplinkAlertSinceUnix)
	st.Incidents.Uplink.LastNotify = fromUnix(c.UplinkLastAlertUnix)
	st.Incidents.Engine.Since = fromUnix(c.EngineAlertSinceUnix)
	st.Incidents.Engine.LastNotify = fromUnix(c.EngineLastAlertUnix)
	st.Incidents.MutedUntil = fromUnix(c.MutedUntilUnix)
	return st
}

func fromUnix(v int64) time.Time {
	if v <= 0 {
		return time.Time{}
	}
	return time.Unix(v, 0)
}

// saveState — обратный путь: бот сообщает, что нужно запомнить.
func (s *telegramBotStore) saveState(st tgbot.PersistedState) error {
	s.mu.Lock()
	cur := s.cur
	cur.StatusMessageID = st.MessageID
	cur.AlertActive = st.Incidents.Availability.Active
	cur.LastPercentage = st.Incidents.Availability.LastPct
	cur.HasPercentage = st.Incidents.Availability.HasPct
	cur.AlertSinceUnix = unixOrZero(st.Incidents.Availability.Since)
	cur.LastAlertUnix = unixOrZero(st.Incidents.Availability.LastNotify)
	cur.UplinkAlertActive = st.Incidents.Uplink.Active
	cur.UplinkAlertSinceUnix = unixOrZero(st.Incidents.Uplink.Since)
	cur.UplinkLastAlertUnix = unixOrZero(st.Incidents.Uplink.LastNotify)
	cur.EngineAlertActive = st.Incidents.Engine.Active
	cur.EngineAlertSinceUnix = unixOrZero(st.Incidents.Engine.Since)
	cur.EngineLastAlertUnix = unixOrZero(st.Incidents.Engine.LastNotify)
	cur.LastKnownIP = st.Incidents.LastKnownIP
	cur.MutedUntilUnix = unixOrZero(st.Incidents.MutedUntil)
	cur.MuteForever = st.Incidents.MuteForever
	s.cur = cur
	s.mu.Unlock()
	return s.write(cur)
}

func unixOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// setConfig применяет патч из формы: nil-поля остаются как были.
func (s *telegramBotStore) setConfig(patch TelegramBotConfig) error {
	s.mu.Lock()
	cur := s.cur
	if patch.Enabled != nil {
		cur.Enabled = patch.Enabled
	}
	if patch.Token != nil {
		cur.Token = patch.Token
	}
	if patch.AdminID != nil {
		cur.AdminID = patch.AdminID
	}
	if patch.AlertThreshold != nil {
		cur.AlertThreshold = patch.AlertThreshold
	}
	if patch.ConnectFailThreshold != nil {
		cur.ConnectFailThreshold = patch.ConnectFailThreshold
	}
	s.cur = cur
	s.mu.Unlock()
	return s.write(cur)
}

func (s *telegramBotStore) write(c TelegramBotConfig) error {
	if s.path == "" {
		return nil // без data_dir настройки живут до перезапуска
	}
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	// Через временный файл: оборванная запись оставила бы обрезанный JSON, и
	// следующий старт молча потерял бы токен вместе с id сообщения.
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// connectFailThreshold — порог доли неудачных подключений для наблюдения за
// связью. Ноль означает «не задан», тогда берётся умолчание пакета.
func (s *telegramBotStore) connectFailThreshold() float64 {
	c := s.get()
	if c.ConnectFailThreshold != nil && *c.ConnectFailThreshold > 0 {
		return *c.ConnectFailThreshold
	}
	return uplink.DefaultFailRateThreshold
}

func (s *telegramBotStore) hasToken() bool {
	c := s.get()
	return c.Token != nil && *c.Token != ""
}

// botTokenRe — форма токена от @BotFather: числовой id бота, двоеточие и
// секрет. Проверяем, чтобы очевидная опечатка не уходила в Telegram и не
// возвращалась невнятным 404.
var botTokenRe = regexp.MustCompile(`^\d{5,15}:[A-Za-z0-9_-]{30,}$`)

// registerTelegramRoutes — настройки бота. Секрет наружу не отдаётся: браузеру
// достаточно знать, что токен задан.
func (s *Server) registerTelegramRoutes(mux *http.ServeMux, jwtSecret []byte) {
	protected := func(h http.HandlerFunc) http.Handler {
		return auth.RequireAuth(jwtSecret, h)
	}

	mux.Handle("GET /api/telegram/status", protected(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: s.telegramStatus()})
	}))

	mux.Handle("PUT /api/telegram/config", protected(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Enabled              *bool    `json:"enabled"`
			Token                *string  `json:"token"`
			AdminID              *int64   `json:"admin_id"`
			AlertThreshold       *float64 `json:"alert_threshold"`
			ConnectFailThreshold *float64 `json:"connect_fail_threshold"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Не удалось разобрать запрос")
			return
		}

		patch := TelegramBotConfig{
			Enabled:              body.Enabled,
			AdminID:              body.AdminID,
			AlertThreshold:       body.AlertThreshold,
			ConnectFailThreshold: body.ConnectFailThreshold,
		}
		if body.Token != nil {
			tok := strings.TrimSpace(*body.Token)
			if tok != "" && !botTokenRe.MatchString(tok) {
				writeError(w, http.StatusBadRequest, "invalid_token",
					"Токен бота выглядит как 123456789:AA... — получите его у @BotFather")
				return
			}
			patch.Token = &tok
		}
		if body.AdminID != nil && *body.AdminID < 0 {
			// Отрицательный id — это группа или канал. Статус идёт в личку:
			// в группе кнопку нажимает один, а проверять права надо у другого,
			// и одно живое сообщение там теряется среди чужих.
			writeError(w, http.StatusBadRequest, "invalid_admin_id",
				"Нужен ID личного чата — напишите боту /start, он пришлёт ваш ID")
			return
		}
		if body.AlertThreshold != nil && (*body.AlertThreshold < 1 || *body.AlertThreshold > 99) {
			writeError(w, http.StatusBadRequest, "invalid_threshold",
				"Порог алерта — от 1 до 99 процентов")
			return
		}
		if body.ConnectFailThreshold != nil && (*body.ConnectFailThreshold < 1 || *body.ConnectFailThreshold > 100) {
			writeError(w, http.StatusBadRequest, "invalid_connect_threshold",
				"Порог ошибок подключения — от 1 до 100 процентов")
			return
		}

		// Включать бота без токена и получателя бессмысленно: он не сможет
		// ни написать, ни принять нажатие кнопки.
		next := s.telegramStore.mergedFor(patch)
		if next.Enabled && (next.Token == "" || next.AdminID == 0) {
			writeError(w, http.StatusBadRequest, "not_configured",
				"Чтобы включить бота, задайте токен и ID админа")
			return
		}

		if err := s.telegramStore.setConfig(patch); err != nil {
			log.Printf("[tgbot] не удалось сохранить настройки: %s", err)
			writeError(w, http.StatusInternalServerError, "save_failed",
				"Настройки приняты, но сохранить их не удалось — после перезапуска панели вернутся прежние")
			return
		}
		if s.telegram != nil {
			s.telegram.Reconfigure(s.telegramStore.botConfig())
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: s.telegramStatus()})
	}))

	mux.Handle("POST /api/telegram/test", protected(func(w http.ResponseWriter, r *http.Request) {
		if s.telegram == nil {
			writeError(w, http.StatusBadRequest, "disabled",
				"Бот не запущен — панель поднялась без него")
			return
		}
		username, err := s.telegram.TestConnection(r.Context())
		if err != nil {
			code := "test_failed"
			switch {
			case errors.Is(err, tgbot.ErrNoToken):
				code = "no_token"
			case errors.Is(err, tgbot.ErrNoAdmin):
				code = "no_admin"
			}
			writeError(w, http.StatusBadRequest, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: map[string]any{
			"bot_username": username,
			"sent":         true,
		}})
	}))
}

// mergedFor показывает, какой станет конфигурация после патча, — нужно, чтобы
// отказать во включении бота, у которого нет ни токена, ни получателя.
func (s *telegramBotStore) mergedFor(patch TelegramBotConfig) tgbot.Config {
	cfg := s.botConfig()
	if patch.Enabled != nil {
		cfg.Enabled = *patch.Enabled
	}
	if patch.Token != nil {
		cfg.Token = *patch.Token
	}
	if patch.AdminID != nil {
		cfg.AdminID = *patch.AdminID
	}
	if patch.AlertThreshold != nil && *patch.AlertThreshold > 0 {
		cfg.AlertThreshold = *patch.AlertThreshold
	}
	return cfg
}

func (s *Server) telegramStatus() map[string]any {
	cfg := s.telegramStore.botConfig()
	out := map[string]any{
		// available=false значит, что выключена сама проверка доступности:
		// без неё боту нечего рассказывать.
		"available":              s.telegram != nil,
		"enabled":                cfg.Enabled,
		"has_token":              s.telegramStore.hasToken(),
		"admin_id":               cfg.AdminID,
		"alert_threshold":        cfg.AlertThreshold,
		"connect_fail_threshold": s.telegramStore.connectFailThreshold(),
	}
	if s.uplink != nil {
		out["uplink"] = s.uplink.Snapshot()
	}
	if s.telegram != nil {
		st := s.telegram.Status()
		out["running"] = st.Running
		out["bot_username"] = st.BotUsername
		out["last_error"] = st.LastError
		out["status_message_id"] = st.MessageID
	}
	return out
}

// startTelegramBot поднимает бота рядом с проверкой доступности и подписывает
// его на вердикты. Живёт здесь, а не в registerTelegramRoutes: боту нужен уже
// собранный Checker, а маршруты регистрируются независимо от него.
func (s *Server) startTelegramBot(client *mtproxylctl.Client) {
	// Наблюдатель за исходящей связью. Живёт рядом с проверкой доступности, но
	// независимо от неё: они смотрят в разные стороны и ловят разные аварии.
	//
	// Именно поэтому запускается и тогда, когда внешняя проверка выключена в
	// конфиге: её данные идут из интернета и стоят квоты, а эти — локальные,
	// от самого движка. Терять мониторинг связи вместе с ней незачем.
	s.uplink = uplink.NewWatcher(
		uplink.NewClient(s.cfg.Telemt.URL, s.cfg.Telemt.AuthHeader),
		uplink.DefaultInterval,
		s.telegramStore.connectFailThreshold,
	)

	deps := tgbot.Deps{
		UplinkSnapshot:      s.uplink.Snapshot,
		Persist:             s.telegramStore.saveState,
		AvailabilityEnabled: s.availability != nil,
	}
	if s.availability != nil {
		deps.RunCheckNow = s.availability.RunCheckNow
		deps.Snapshot = s.availability.Store().Get
		deps.Quota = s.availability.Quota
		deps.AutoCheck = s.availabilityOverride.autoCheckEnabled
		deps.Target = s.availabilityTarget(client)
		deps.Interval = s.cfg.Globalping.Interval()
	}

	bot := tgbot.New(deps, s.telegramStore.botState())

	s.telegram = bot
	bot.Reconfigure(s.telegramStore.botConfig())

	// Подписка ставится до старта проверки: первый же вердикт должен попасть
	// в чат, а не потеряться из-за того, что бот ещё не слушал.
	if s.availability != nil {
		s.availability.SetOnResult(bot.OnResult)
	}
	s.uplink.SetOnResult(bot.OnUplink)
	bot.Start(context.Background())
	go s.uplink.Start(context.Background())

	if cfg := s.telegramStore.botConfig(); cfg.Enabled {
		log.Println("[tgbot] телеграм-бот включён")
	}
}
