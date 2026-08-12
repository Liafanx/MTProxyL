package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/tgbot"
	"github.com/Liafanx/mtproxyl-panel/internal/uplink"
)

const goodToken = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"

func newTelegramMux(t *testing.T, dataDir string) (*http.ServeMux, *Server) {
	t.Helper()
	s := New(&config.Config{DataDir: dataDir})
	s.telegramStore = newTelegramBotStore(dataDir)
	mux := http.NewServeMux()
	s.registerTelegramRoutes(mux, testJWTSecret)
	return mux, s
}

func decodeData(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var resp struct {
		OK    bool           `json:"ok"`
		Data  map[string]any `json:"data"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("ответ не разобран: %v (%s)", err, rec.Body.String())
	}
	if !resp.OK {
		t.Fatalf("ok=false: %s / %s", resp.Error.Code, resp.Error.Message)
	}
	return resp.Data
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var resp struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("ответ не разобран: %v (%s)", err, rec.Body.String())
	}
	return resp.Error.Code
}

func TestTelegramRoutesRequireAuth(t *testing.T) {
	mux, _ := newTelegramMux(t, t.TempDir())

	cases := []struct {
		method, target string
	}{
		{http.MethodGet, "/api/telegram/status"},
		{http.MethodPut, "/api/telegram/config"},
		{http.MethodPost, "/api/telegram/test"},
	}
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.target, strings.NewReader("{}")))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s без авторизации: %d, want 401", tc.method, tc.target, rec.Code)
		}
	}
}

// Токен наружу не отдаётся: браузеру достаточно знать, что он задан. Возить
// секрет в интерфейс на каждую загрузку страницы незачем.
func TestTelegramStatusNeverReturnsToken(t *testing.T) {
	dir := t.TempDir()
	mux, s := newTelegramMux(t, dir)

	tok := goodToken
	if err := s.telegramStore.setConfig(TelegramBotConfig{Token: &tok}); err != nil {
		t.Fatalf("setConfig: %v", err)
	}

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/telegram/status", ""))

	if strings.Contains(rec.Body.String(), goodToken) {
		t.Fatalf("токен ушёл в браузер: %s", rec.Body.String())
	}
	if data := decodeData(t, rec); data["has_token"] != true {
		t.Errorf("has_token = %v, ожидалось true", data["has_token"])
	}
}

func TestTelegramConfigValidation(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		wantCode string
	}{
		{"кривой токен", `{"token":"не-токен"}`, "invalid_token"},
		{"порог ниже допустимого", `{"alert_threshold":0.5}`, "invalid_threshold"},
		{"порог выше допустимого", `{"alert_threshold":120}`, "invalid_threshold"},
		{"id группы вместо лички", `{"admin_id":-1001234567890}`, "invalid_admin_id"},
		{"включение без токена", `{"enabled":true}`, "not_configured"},
		{"мусор вместо json", `{`, "bad_request"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mux, _ := newTelegramMux(t, t.TempDir())
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/telegram/config", tc.body))

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("код %d, want 400 (%s)", rec.Code, rec.Body.String())
			}
			if got := errorCode(t, rec); got != tc.wantCode {
				t.Errorf("код ошибки = %q, want %q", got, tc.wantCode)
			}
		})
	}
}

func TestTelegramConfigAcceptsValidSettings(t *testing.T) {
	dir := t.TempDir()
	mux, s := newTelegramMux(t, dir)

	rec := httptest.NewRecorder()
	body := `{"token":"` + goodToken + `","admin_id":555,"alert_threshold":70,"enabled":true}`
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/telegram/config", body))

	if rec.Code != http.StatusOK {
		t.Fatalf("код %d: %s", rec.Code, rec.Body.String())
	}
	data := decodeData(t, rec)
	if data["enabled"] != true || data["admin_id"] != float64(555) || data["alert_threshold"] != float64(70) {
		t.Errorf("ответ = %+v", data)
	}

	cfg := s.telegramStore.botConfig()
	if cfg.Token != goodToken || cfg.AdminID != 555 || cfg.AlertThreshold != 70 {
		t.Errorf("сохранено %+v", cfg)
	}
}

// Форма присылает только своё поле: сохранение порога не должно стирать токен.
func TestTelegramConfigPatchKeepsUntouchedFields(t *testing.T) {
	dir := t.TempDir()
	mux, s := newTelegramMux(t, dir)

	first := `{"token":"` + goodToken + `","admin_id":555}`
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/telegram/config", first))
	if rec.Code != http.StatusOK {
		t.Fatalf("первый запрос: %d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/telegram/config", `{"alert_threshold":50}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("второй запрос: %d %s", rec.Code, rec.Body.String())
	}

	cfg := s.telegramStore.botConfig()
	if cfg.Token != goodToken {
		t.Errorf("токен потерян после правки порога: %+v", cfg)
	}
	if cfg.AdminID != 555 {
		t.Errorf("ID админа потерян после правки порога: %+v", cfg)
	}
	if cfg.AlertThreshold != 50 {
		t.Errorf("порог не сохранился: %+v", cfg)
	}
}

// Пустой токен — это «убрать», а не «оставить как было».
func TestTelegramConfigEmptyTokenClearsIt(t *testing.T) {
	dir := t.TempDir()
	mux, s := newTelegramMux(t, dir)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/telegram/config",
		`{"token":"`+goodToken+`","admin_id":555}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPut, "/api/telegram/config", `{"token":""}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}

	if s.telegramStore.hasToken() {
		t.Error("токен не убрался пустым значением")
	}
}

func TestTelegramTestWithoutCheckerIsRefused(t *testing.T) {
	mux, _ := newTelegramMux(t, t.TempDir())

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/telegram/test", ""))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("код %d, want 400", rec.Code)
	}
	if got := errorCode(t, rec); got != "disabled" {
		t.Errorf("код = %q, want disabled", got)
	}
}

// ── Хранилище ───────────────────────────────────────────────────────────────

func TestTelegramStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := newTelegramBotStore(dir)

	enabled := true
	tok := goodToken
	admin := int64(555)
	threshold := 70.0
	if err := s.setConfig(TelegramBotConfig{Enabled: &enabled, Token: &tok, AdminID: &admin, AlertThreshold: &threshold}); err != nil {
		t.Fatalf("setConfig: %v", err)
	}

	reloaded := newTelegramBotStore(dir)
	cfg := reloaded.botConfig()
	if !cfg.Enabled || cfg.Token != goodToken || cfg.AdminID != 555 || cfg.AlertThreshold != 70 {
		t.Errorf("после перезагрузки: %+v", cfg)
	}
}

// Именно это переживание перезапуска и делает сообщение одним: без id бот
// прислал бы новое, а без состояния алерта — повторный алерт посреди аварии.
func TestTelegramStoreKeepsBotMemoryAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	s := newTelegramBotStore(dir)

	since := time.Now().Add(-time.Hour).Truncate(time.Second)
	notify := time.Now().Add(-10 * time.Minute).Truncate(time.Second)
	state := tgbot.PersistedState{
		MessageID: 4242,
		Incidents: tgbot.Incidents{
			Availability: tgbot.AlertState{Active: true, Since: since, LastNotify: notify, LastPct: 45, HasPct: true},
			Uplink:       tgbot.IncidentState{Active: true, Since: since, LastNotify: notify},
			LastKnownIP:  "203.0.113.10",
			MutedUntil:   notify,
		},
	}
	if err := s.saveState(state); err != nil {
		t.Fatalf("saveState: %v", err)
	}

	got := newTelegramBotStore(dir).botState()
	if got.MessageID != 4242 {
		t.Errorf("MessageID = %d, want 4242", got.MessageID)
	}
	av := got.Incidents.Availability
	if !av.Active || !av.HasPct || av.LastPct != 45 {
		t.Errorf("доступность = %+v", av)
	}
	if !av.Since.Equal(since) || !av.LastNotify.Equal(notify) {
		t.Errorf("времена не совпали: %+v против since=%v notify=%v", av, since, notify)
	}
	if !got.Incidents.Uplink.Active || !got.Incidents.Uplink.Since.Equal(since) {
		t.Errorf("состояние связи не пережило перезапуск: %+v", got.Incidents.Uplink)
	}
	if got.Incidents.LastKnownIP != "203.0.113.10" {
		t.Errorf("LastKnownIP = %q", got.Incidents.LastKnownIP)
	}
	if !got.Incidents.MutedUntil.Equal(notify) {
		t.Errorf("пауза не пережила перезапуск: %v", got.Incidents.MutedUntil)
	}
}

// Сохранение состояния бота не должно стирать настройки, и наоборот.
func TestTelegramStoreStateAndConfigCoexist(t *testing.T) {
	dir := t.TempDir()
	s := newTelegramBotStore(dir)

	tok := goodToken
	if err := s.setConfig(TelegramBotConfig{Token: &tok}); err != nil {
		t.Fatalf("setConfig: %v", err)
	}
	if err := s.saveState(tgbot.PersistedState{MessageID: 7}); err != nil {
		t.Fatalf("saveState: %v", err)
	}

	reloaded := newTelegramBotStore(dir)
	if !reloaded.hasToken() {
		t.Error("сохранение состояния стёрло токен")
	}
	if reloaded.botState().MessageID != 7 {
		t.Error("id сообщения не сохранился")
	}
}

// Битый файл не должен мешать панели подняться.
func TestTelegramStoreSurvivesCorruptFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, telegramBotFile), []byte("{не json"), 0o600); err != nil {
		t.Fatalf("подготовка: %v", err)
	}

	s := newTelegramBotStore(dir)
	if cfg := s.botConfig(); cfg.Enabled || cfg.Token != "" {
		t.Errorf("из битого файла что-то прочиталось: %+v", cfg)
	}

	tok := goodToken
	if err := s.setConfig(TelegramBotConfig{Token: &tok}); err != nil {
		t.Fatalf("запись поверх битого файла: %v", err)
	}
	if !newTelegramBotStore(dir).hasToken() {
		t.Error("после перезаписи токен не читается")
	}
}

// Без data_dir настройки живут до перезапуска — панель не должна падать.
func TestTelegramStoreWithoutDataDir(t *testing.T) {
	s := newTelegramBotStore("")
	tok := goodToken
	if err := s.setConfig(TelegramBotConfig{Token: &tok}); err != nil {
		t.Fatalf("setConfig без data_dir: %v", err)
	}
	if !s.hasToken() {
		t.Error("настройки не применились в памяти")
	}
}

func TestTelegramStoreFileIsNotWorldReadable(t *testing.T) {
	dir := t.TempDir()
	s := newTelegramBotStore(dir)
	tok := goodToken
	if err := s.setConfig(TelegramBotConfig{Token: &tok}); err != nil {
		t.Fatalf("setConfig: %v", err)
	}

	st, err := os.Stat(filepath.Join(dir, telegramBotFile))
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Errorf("права %o, ожидались 600: в файле лежит токен бота", perm)
	}
}

func TestBotTokenPattern(t *testing.T) {
	cases := map[string]bool{
		goodToken: true,
		"123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw-_": true,
		"12345:short":       false,
		"nodigits:AAHdqTcv": false,
		"123456789 AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw": false,
		"": false,
		"123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw\nX": false,
	}
	for token, want := range cases {
		if got := botTokenRe.MatchString(token); got != want {
			t.Errorf("botTokenRe(%q) = %v, want %v", token, got, want)
		}
	}
}

// Файл из первой версии бота уже лежит у пользователей. Обновление обязано
// прочитать его без потерь: новых ключей там нет, и ноль в них означает
// «инцидента не было», а не «авария» — ложной тревоги задним числом быть не
// должно.
func TestTelegramStoreReadsPreUplinkFile(t *testing.T) {
	dir := t.TempDir()
	old := `{"enabled":true,"token":"` + goodToken + `","admin_id":555,"alert_threshold":60,` +
		`"status_message_id":4242,"alert_active":true,"alert_since_unix":1750000000,` +
		`"last_alert_unix":1750001000,"last_percentage":45,"has_percentage":true}`
	if err := os.WriteFile(filepath.Join(dir, telegramBotFile), []byte(old), 0o600); err != nil {
		t.Fatalf("подготовка: %v", err)
	}

	s := newTelegramBotStore(dir)

	cfg := s.botConfig()
	if !cfg.Enabled || cfg.Token != goodToken || cfg.AdminID != 555 {
		t.Errorf("настройки из старого файла потеряны: %+v", cfg)
	}

	st := s.botState()
	if st.MessageID != 4242 {
		t.Errorf("MessageID = %d — бот прислал бы новое сообщение вместо правки старого", st.MessageID)
	}
	if !st.Incidents.Availability.Active || st.Incidents.Availability.LastPct != 45 {
		t.Errorf("состояние аварии доступности потеряно: %+v", st.Incidents.Availability)
	}
	if st.Incidents.Uplink.Active || st.Incidents.Engine.Active {
		t.Errorf("новые инциденты прочитались активными из старого файла: %+v", st.Incidents)
	}
	if st.Incidents.Muted(time.Now()) {
		t.Error("из старого файла прочиталась пауза, которой там нет")
	}
	if s.connectFailThreshold() != uplink.DefaultFailRateThreshold {
		t.Errorf("порог ошибок = %v, ожидалось умолчание", s.connectFailThreshold())
	}
}

// И наоборот: запись поверх старого файла не должна терять его поля.
func TestTelegramStoreUpgradesFileInPlace(t *testing.T) {
	dir := t.TempDir()
	old := `{"enabled":true,"token":"` + goodToken + `","admin_id":555,"status_message_id":4242}`
	if err := os.WriteFile(filepath.Join(dir, telegramBotFile), []byte(old), 0o600); err != nil {
		t.Fatalf("подготовка: %v", err)
	}

	s := newTelegramBotStore(dir)
	if err := s.saveState(tgbot.PersistedState{
		MessageID: 4242,
		Incidents: tgbot.Incidents{Uplink: tgbot.IncidentState{Active: true}},
	}); err != nil {
		t.Fatalf("saveState: %v", err)
	}

	reloaded := newTelegramBotStore(dir)
	if !reloaded.hasToken() || reloaded.botConfig().AdminID != 555 {
		t.Errorf("настройки потеряны при дозаписи состояния: %+v", reloaded.botConfig())
	}
	if !reloaded.botState().Incidents.Uplink.Active {
		t.Error("новое состояние не сохранилось")
	}
}
