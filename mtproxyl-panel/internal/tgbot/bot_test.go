package tgbot

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

// recorder — подставной Bot API, который запоминает вызовы. reply решает, что
// ответить на конкретный метод; nil-ответ означает «ok».
type recorder struct {
	mu    sync.Mutex
	calls []call
	reply map[string]func(w http.ResponseWriter)
}

type call struct {
	Method string
	Body   map[string]any
}

func newRecorder(t *testing.T) (*recorder, *Client) {
	t.Helper()
	rec := &recorder{reply: map[string]func(w http.ResponseWriter){}}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		method := parts[len(parts)-1]

		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)

		rec.mu.Lock()
		rec.calls = append(rec.calls, call{Method: method, Body: body})
		// Счётчик снимаем под тем же мьютексом: опрос и воркер ходят сюда
		// одновременно, и чтение длины снаружи было бы гонкой в самом тесте.
		seq := len(rec.calls)
		fn := rec.reply[method]
		rec.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		if fn != nil {
			fn(w)
			return
		}
		switch method {
		case "sendMessage":
			okResult(w, Message{MessageID: 100 + seq, Chat: Chat{ID: 555}})
		case "getMe":
			okResult(w, User{ID: 1, IsBot: true, Username: "test_bot"})
		default:
			_, _ = w.Write([]byte(`{"ok":true,"result":true}`))
		}
	}))
	t.Cleanup(srv.Close)

	c := NewClient("123456:test")
	c.baseURL = srv.URL
	return rec, c
}

func (r *recorder) methods() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.calls))
	for _, c := range r.calls {
		out = append(out, c.Method)
	}
	return out
}

func (r *recorder) find(method string) *call {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.calls {
		if r.calls[i].Method == method {
			return &r.calls[i]
		}
	}
	return nil
}

func (r *recorder) count(method string) int {
	n := 0
	for _, m := range r.methods() {
		if m == method {
			n++
		}
	}
	return n
}

func newTestBot(t *testing.T, deps Deps, state PersistedState) (*Bot, *recorder) {
	t.Helper()
	rec, client := newRecorder(t)
	b := New(deps, state)
	b.cfg = Config{Enabled: true, Token: "123456:test", AdminID: 555, AlertThreshold: DefaultThreshold}
	b.client = client
	b.now = func() time.Time { return time.Date(2026, 8, 11, 17, 30, 0, 0, time.UTC) }
	return b, rec
}

// Обычная проверка правит то же сообщение: в чате одно живое сообщение, и
// автообновление панели не должно превращаться в ленту.
func TestDeliverEditsExistingMessage(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77})
	b.lastGood = verdict(95)

	b.deliver(context.Background(), Decision{Event: EventNone})

	if rec.count("editMessageText") != 1 {
		t.Errorf("вызовы: %v, ожидалась одна правка", rec.methods())
	}
	if rec.count("sendMessage") != 0 {
		t.Errorf("вызовы: %v, отправка нового сообщения не ожидалась", rec.methods())
	}
}

// Событие требует звука, а правка его не даёт: значит новое сообщение, и
// только потом уборка прежнего.
func TestDeliverRecreatesMessageOnEvent(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77})
	b.lastGood = verdict(55)

	b.deliver(context.Background(), Decision{Event: EventDown, AlertSince: b.now()})

	methods := rec.methods()
	if len(methods) < 2 || methods[0] != "sendMessage" || methods[1] != "deleteMessage" {
		t.Fatalf("порядок вызовов %v, ожидалось sendMessage → deleteMessage", methods)
	}
	if b.state.MessageID == 77 || b.state.MessageID == 0 {
		t.Errorf("MessageID = %d, ожидался id нового сообщения", b.state.MessageID)
	}
	if del := rec.find("deleteMessage"); del == nil || del.Body["message_id"] != float64(77) {
		t.Errorf("удалено не прежнее сообщение: %+v", del)
	}
	if send := rec.find("sendMessage"); send == nil || send.Body["disable_notification"] != false {
		t.Errorf("алерт ушёл без звука: %+v", send)
	}
}

// Telegram не даёт удалять свои сообщения старше 48 часов. Панель вполне может
// проработать двое суток без событий, поэтому неудаляемое надо ужать, чтобы в
// чате не осталось второго «статуса» со старыми цифрами.
func TestDeliverTombstonesUndeletableMessage(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77})
	b.lastGood = verdict(55)
	rec.reply["deleteMessage"] = func(w http.ResponseWriter) {
		apiFailure(w, 400, "Bad Request: message can't be deleted")
	}

	b.deliver(context.Background(), Decision{Event: EventDown})

	edit := rec.find("editMessageText")
	if edit == nil {
		t.Fatalf("вызовы %v, ожидалась замена прежнего сообщения надгробием", rec.methods())
	}
	if text, _ := edit.Body["text"].(string); !strings.Contains(text, "Актуальный статус") {
		t.Errorf("текст надгробия = %q", text)
	}
}

// Сообщение удалили руками — правка не пройдёт, и бот обязан прислать новое, а
// не замолчать навсегда.
func TestDeliverSendsNewWhenMessageGone(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77})
	b.lastGood = verdict(95)
	rec.reply["editMessageText"] = func(w http.ResponseWriter) {
		apiFailure(w, 400, "Bad Request: message to edit not found")
	}

	b.deliver(context.Background(), Decision{Event: EventNone})

	if rec.count("sendMessage") != 1 {
		t.Errorf("вызовы %v, ожидалась отправка нового сообщения", rec.methods())
	}
	if rec.count("deleteMessage") != 0 {
		t.Errorf("вызовы %v: удалять нечего, сообщения уже нет", rec.methods())
	}
	if b.state.MessageID == 77 {
		t.Error("id не обновился на новое сообщение")
	}
}

// «Текст не изменился» — штатный ответ на повторную отрисовку того же
// вердикта. Ошибкой в панели он выглядеть не должен.
func TestDeliverTreatsNotModifiedAsSuccess(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{MessageID: 77})
	b.lastGood = verdict(95)
	rec.reply["editMessageText"] = func(w http.ResponseWriter) {
		apiFailure(w, 400, "Bad Request: message is not modified")
	}

	b.deliver(context.Background(), Decision{Event: EventNone})

	if got := b.Status().LastError; got != "" {
		t.Errorf("LastError = %q, повтор того же текста ошибкой не является", got)
	}
	if rec.count("sendMessage") != 0 {
		t.Errorf("вызовы %v: пересоздавать сообщение из-за повтора не нужно", rec.methods())
	}
}

func TestDeliverDoesNothingWhenDisabled(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})
	b.cfg.Enabled = false
	b.lastGood = verdict(95)

	b.deliver(context.Background(), Decision{Event: EventNone})

	if len(rec.methods()) != 0 {
		t.Errorf("выключенный бот сходил в Telegram: %v", rec.methods())
	}
}

func TestDeliverDoesNothingWithoutAdmin(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})
	b.cfg.AdminID = 0
	b.lastGood = verdict(95)

	b.deliver(context.Background(), Decision{Event: EventNone})

	if len(rec.methods()) != 0 {
		t.Errorf("без ID админа бот сходил в Telegram: %v", rec.methods())
	}
}

// OnResult зовут из середины проверки доступности: он обязан возвращаться
// мгновенно, даже когда воркер не запущен и канал занят.
func TestOnResultNeverBlocks(t *testing.T) {
	b := New(Deps{}, PersistedState{})

	done := make(chan struct{})
	go func() {
		for i := 0; i < 1000; i++ {
			b.OnResult(verdict(float64(i % 100)))
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("OnResult заблокировался — проверка доступности встала бы вместе с ним")
	}
}

// В канале копится не очередь, а только самый свежий вердикт: старый всё равно
// был бы перерисован поверх.
func TestOnResultKeepsOnlyLatest(t *testing.T) {
	b := New(Deps{}, PersistedState{})

	b.OnResult(verdict(10))
	b.OnResult(verdict(20))
	b.OnResult(verdict(95))

	select {
	case got := <-b.results:
		if got.Percentage != 95 {
			t.Errorf("в канале %.0f%%, ожидался самый свежий 95%%", got.Percentage)
		}
	default:
		t.Fatal("канал пуст")
	}
	select {
	case extra := <-b.results:
		t.Fatalf("в канале осталось лишнее: %.0f%%", extra.Percentage)
	default:
	}
}

func TestHandleResultPersistsAlertState(t *testing.T) {
	var saved []PersistedState
	var mu sync.Mutex
	b, _ := newTestBot(t, Deps{
		Persist: func(s PersistedState) error {
			mu.Lock()
			saved = append(saved, s)
			mu.Unlock()
			return nil
		},
	}, PersistedState{MessageID: 77})

	b.handleResult(context.Background(), verdict(40))

	mu.Lock()
	defer mu.Unlock()
	if len(saved) == 0 {
		t.Fatal("состояние не сохранено")
	}
	if !saved[0].Alert.Active {
		t.Errorf("Alert.Active = false после падения ниже порога: %+v", saved[0].Alert)
	}
}

// Сорвавшаяся проверка не затирает последний удачный вердикт — иначе
// сообщение показывало бы 0% там, где измерения просто не было.
func TestHandleResultKeepsLastGoodOnFailure(t *testing.T) {
	b, _ := newTestBot(t, Deps{}, PersistedState{MessageID: 77})
	good := verdict(95)

	b.handleResult(context.Background(), good)
	b.handleResult(context.Background(), &globalping.CheckResult{Error: "сервис не отвечает"})

	if b.lastGood != good {
		t.Error("последний удачный вердикт потерян")
	}
	if b.lastFail == nil || b.lastFail.Reason != "сервис не отвечает" {
		t.Errorf("причина неудачи не сохранена: %+v", b.lastFail)
	}
}

func TestCallbackFromStrangerIsRejected(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	b.handleCallback(context.Background(), b.client, 555, &CallbackQuery{
		ID: "q1", From: User{ID: 999}, Data: callbackCheck,
	})

	answer := rec.find("answerCallbackQuery")
	if answer == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	if answer.Body["show_alert"] != true {
		t.Errorf("отказ показан без всплывашки: %+v", answer.Body)
	}
	if text, _ := answer.Body["text"].(string); !strings.Contains(text, "не для вас") {
		t.Errorf("текст отказа = %q", text)
	}
}

// Кулдаун отвечает мгновенно — значит человеку можно показать, сколько ждать,
// прямо всплывашкой на кнопке.
func TestCallbackCheckShowsImmediateRefusal(t *testing.T) {
	b, rec := newTestBot(t, Deps{
		RunCheckNow: func(context.Context) (*globalping.CheckResult, error) {
			return nil, errors.New("проверка была 12 с назад — подождите 48 с")
		},
	}, PersistedState{})

	b.handleCallback(context.Background(), b.client, 555, &CallbackQuery{
		ID: "q1", From: User{ID: 555}, Data: callbackCheck,
	})

	answer := rec.find("answerCallbackQuery")
	if answer == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	if text, _ := answer.Body["text"].(string); !strings.Contains(text, "подождите 48 с") {
		t.Errorf("причина отказа не показана: %q", text)
	}
	if answer.Body["show_alert"] != true {
		t.Errorf("отказ показан без всплывашки: %+v", answer.Body)
	}
}

func TestCallbackRefreshAsksForRedraw(t *testing.T) {
	b, _ := newTestBot(t, Deps{}, PersistedState{})

	b.handleCallback(context.Background(), b.client, 555, &CallbackQuery{
		ID: "q1", From: User{ID: 555}, Data: callbackRefresh,
	})

	select {
	case <-b.redraw:
	default:
		t.Error("кнопка «Обновить» не попросила перерисовать сообщение")
	}
}

// Пока ID админа не задан, /start — единственный способ его узнать, поэтому
// отвечаем всем. Как только ID известен, посторонние получают отказ.
func TestStartRepliesWithChatIDUntilAdminIsSet(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	b.handleMessage(context.Background(), b.client, 0, &Message{Text: "/start", Chat: Chat{ID: 424242}})

	send := rec.find("sendMessage")
	if send == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	if text, _ := send.Body["text"].(string); !strings.Contains(text, "424242") {
		t.Errorf("в ответе нет chat_id: %q", text)
	}
}

func TestStartFromStrangerIsRefusedOnceAdminIsKnown(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	b.handleMessage(context.Background(), b.client, 555, &Message{Text: "/start", Chat: Chat{ID: 999}})

	send := rec.find("sendMessage")
	if send == nil {
		t.Fatalf("вызовы %v", rec.methods())
	}
	if text, _ := send.Body["text"].(string); !strings.Contains(text, "чужую панель") {
		t.Errorf("посторонний не получил отказ: %q", text)
	}
	if strings.Contains(send.Body["text"].(string), "999") {
		t.Error("постороннему выдан его chat_id вместе с отказом")
	}
}

func TestNonStartMessageIsIgnored(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	b.handleMessage(context.Background(), b.client, 555, &Message{Text: "привет", Chat: Chat{ID: 555}})

	if len(rec.methods()) != 0 {
		t.Errorf("бот ответил на постороннее сообщение: %v", rec.methods())
	}
}

func TestTestConnectionRequiresToken(t *testing.T) {
	b := New(Deps{}, PersistedState{})
	if _, err := b.TestConnection(context.Background()); !errors.Is(err, ErrNoToken) {
		t.Errorf("err = %v, ожидалась ErrNoToken", err)
	}
}

func TestTestConnectionSendsProbeMessage(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})

	username, err := b.TestConnection(context.Background())
	if err != nil {
		t.Fatalf("TestConnection: %v", err)
	}
	if username != "test_bot" {
		t.Errorf("username = %q", username)
	}
	if rec.count("sendMessage") != 1 {
		t.Errorf("вызовы %v, ожидалось пробное сообщение", rec.methods())
	}
}

// Токен есть, а ID админа нет: писать некому, и это надо сказать словами, а не
// молча ничего не сделать.
func TestTestConnectionWithoutAdmin(t *testing.T) {
	b, _ := newTestBot(t, Deps{}, PersistedState{})
	b.cfg.AdminID = 0

	if _, err := b.TestConnection(context.Background()); !errors.Is(err, ErrNoAdmin) {
		t.Errorf("err = %v, ожидалась ErrNoAdmin", err)
	}
}

// Админ не нажимал /start: Telegram не даёт боту написать первым, и панель
// должна объяснить это по-человечески.
func TestDeliverExplainsChatNotFound(t *testing.T) {
	b, rec := newTestBot(t, Deps{}, PersistedState{})
	b.lastGood = verdict(95)
	rec.reply["sendMessage"] = func(w http.ResponseWriter) {
		apiFailure(w, 400, "Bad Request: chat not found")
	}

	b.deliver(context.Background(), Decision{Event: EventNone})

	if got := b.Status().LastError; !strings.Contains(got, "/start") {
		t.Errorf("LastError = %q, ожидалась подсказка про /start", got)
	}
}

// Настройки применяются до Start (панель читает их с диска и сразу отдаёт
// боту), поэтому Start обязан поднять опрос сам. Раньше он звал applyConfig,
// тот видел неизменившуюся конфигурацию и не делал ничего — бот молчал до
// первой правки настроек в панели.
func TestStartBeginsPollingWithPreloadedConfig(t *testing.T) {
	rec, client := newRecorder(t)
	b := New(Deps{}, PersistedState{})
	b.Reconfigure(Config{Enabled: true, Token: "123456:test", AdminID: 555})

	b.mu.Lock()
	b.client = client // подменяем уже после Reconfigure: адрес ведёт на подставной API
	b.mu.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b.Start(ctx)
	t.Cleanup(func() { cancel(); b.pollWG.Wait() })

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if rec.count("getUpdates") > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("опрос Telegram не начался, вызовы: %v", rec.methods())
}

// Горутина опроса захватывает ID админа при запуске. Без перезапуска смена
// админа не дошла бы до проверки прав на кнопках: их принимал бы прежний.
func TestChangingAdminRestartsPolling(t *testing.T) {
	rec, client := newRecorder(t)
	b := New(Deps{}, PersistedState{})
	b.Reconfigure(Config{Enabled: true, Token: "123456:test", AdminID: 555})
	b.mu.Lock()
	b.client = client
	b.mu.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b.Start(ctx)
	t.Cleanup(func() { cancel(); b.pollWG.Wait() })

	waitFor(t, func() bool { return rec.count("getMe") >= 1 })

	b.Reconfigure(Config{Enabled: true, Token: "123456:test", AdminID: 777})

	// Новый цикл опроса начинается с getMe — по нему и видно, что он новый.
	waitFor(t, func() bool { return rec.count("getMe") >= 2 })
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("условие не выполнилось за отведённое время")
}

// Два одновременных сохранения настроек не должны разойтись на WaitGroup.
func TestConcurrentReconfigureIsSafe(t *testing.T) {
	_, client := newRecorder(t)
	b := New(Deps{}, PersistedState{})
	b.mu.Lock()
	b.client = client
	b.mu.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b.Start(ctx)
	t.Cleanup(func() { cancel(); b.pollWG.Wait() })

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b.Reconfigure(Config{Enabled: true, Token: "123456:test", AdminID: int64(500 + i)})
		}(i)
	}
	wg.Wait()
}
