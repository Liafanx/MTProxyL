package tgbot

import (
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

const (
	// callbackCheck запускает настоящее измерение — то же, что кнопка
	// «Проверить сейчас» в панели, с её кулдауном и расходом квоты.
	callbackCheck = "check"
	// callbackRefresh перерисовывает сообщение по уже известному вердикту.
	callbackRefresh = "refresh"

	// fastFailWindow — сколько ждём мгновенного отказа от RunCheckNow, прежде
	// чем сказать человеку «проверяю». Кулдаун и исчерпанная квота отвечают
	// сразу, настоящее измерение — десятки секунд.
	fastFailWindow = 2 * time.Second

	// pollBackoffMin/Max — пауза после сетевого сбоя опроса.
	pollBackoffMin = time.Second
	pollBackoffMax = 30 * time.Second

	// tombstone заменяет прежнее сообщение, если удалить его не вышло:
	// Telegram не даёт боту удалять свои сообщения старше 48 часов.
	tombstone = "⤵️ Актуальный статус — ниже"
)

// ErrNoToken и ErrNoAdmin — не сбои, а незаконченная настройка. Панель
// показывает их текст как подсказку, что осталось сделать.
var (
	ErrNoToken = errors.New("токен бота не задан")
	ErrNoAdmin = errors.New("ID админа не задан: напишите боту /start, он пришлёт ваш ID")
)

// Config — то, что оператор задаёт в панели.
type Config struct {
	Enabled        bool
	Token          string
	AdminID        int64
	AlertThreshold float64
}

// PersistedState — то, что обязано пережить перезапуск панели.
type PersistedState struct {
	MessageID int
	Alert     AlertState
}

// Deps — всё, что боту нужно от остальной панели. Функциями, а не ссылкой на
// *globalping.Checker: пакет знает о проверке только её результат, обратной
// зависимости нет.
type Deps struct {
	RunCheckNow func(context.Context) (*globalping.CheckResult, error)
	Snapshot    func() *globalping.CheckResult
	Quota       func() globalping.QuotaState
	AutoCheck   func() bool
	Target      func(context.Context) (globalping.Target, error)
	Interval    time.Duration
	// Persist сохраняет PersistedState. Может быть nil — тогда состояние
	// живёт до перезапуска.
	Persist func(PersistedState) error
}

// Status — что показать в панели.
type Status struct {
	Running     bool   `json:"running"`
	BotUsername string `json:"bot_username,omitempty"`
	LastError   string `json:"last_error,omitempty"`
	MessageID   int    `json:"status_message_id,omitempty"`
}

// Bot держит одно живое сообщение в личке админа и обновляет его по каждому
// вердикту проверки доступности.
type Bot struct {
	deps     Deps
	resolver *Resolver
	now      func() time.Time

	mu       sync.Mutex
	cfg      Config
	client   *Client
	state    PersistedState
	lastGood *globalping.CheckResult
	lastFail *Failure
	username string
	lastErr  string
	running  bool

	// results принимает вердикты от проверки. Ёмкость 1 с вытеснением: если
	// воркер занят, копится не очередь, а только самый свежий результат.
	results chan *globalping.CheckResult
	// redraw просит перерисовать сообщение без нового измерения.
	redraw chan struct{}

	baseCtx    context.Context
	pollCancel context.CancelFunc
	pollWG     sync.WaitGroup
	started    bool
}

func New(deps Deps, state PersistedState) *Bot {
	return &Bot{
		deps:     deps,
		resolver: NewResolver(),
		now:      time.Now,
		state:    state,
		results:  make(chan *globalping.CheckResult, 1),
		redraw:   make(chan struct{}, 1),
	}
}

// Start запускает воркера. Опрос Telegram поднимется, как только появится
// рабочая конфигурация, — Reconfigure можно звать и до, и после Start.
func (b *Bot) Start(ctx context.Context) {
	b.mu.Lock()
	if b.started {
		b.mu.Unlock()
		return
	}
	b.started = true
	b.baseCtx = ctx
	cfg := b.cfg
	b.mu.Unlock()

	go b.worker(ctx)

	b.applyConfig(cfg)
	b.requestRedraw()
}

// OnResult — подписчик проверки доступности. Обязан возвращаться мгновенно:
// его зовут из середины doCheck, и любая задержка здесь тормозила бы и
// плановый цикл, и HTTP-ответ на «Проверить сейчас».
func (b *Bot) OnResult(r *globalping.CheckResult) {
	if r == nil {
		return
	}
	select {
	case b.results <- r:
	default:
		// Воркер ещё возится с прошлым вердиктом. Очередь здесь не нужна:
		// важен только самый свежий результат, старый всё равно был бы
		// перерисован поверх.
		select {
		case <-b.results:
		default:
		}
		select {
		case b.results <- r:
		default:
		}
	}
}

// Reconfigure применяет настройки из панели без перезапуска процесса.
func (b *Bot) Reconfigure(cfg Config) {
	b.applyConfig(cfg)
	b.requestRedraw()
}

func (b *Bot) applyConfig(cfg Config) {
	b.mu.Lock()
	prev := b.cfg
	b.cfg = cfg
	if cfg.Token != "" {
		if b.client == nil || prev.Token != cfg.Token {
			b.client = NewClient(cfg.Token)
			b.username = ""
		}
	} else {
		b.client = nil
	}
	started := b.started
	sameLoop := prev.Token == cfg.Token && prev.Enabled == cfg.Enabled
	b.mu.Unlock()

	if !started || sameLoop {
		return
	}
	b.restartPolling()
}

// restartPolling останавливает прежний опрос и, если есть с чем, поднимает
// новый. Именно останавливает и дожидается: двух getUpdates одним токеном
// Telegram не разрешает и отвечает на это 409.
func (b *Bot) restartPolling() {
	b.mu.Lock()
	if b.pollCancel != nil {
		b.pollCancel()
		b.pollCancel = nil
	}
	b.mu.Unlock()

	b.pollWG.Wait()

	b.mu.Lock()
	defer b.mu.Unlock()
	if b.baseCtx == nil || !b.cfg.Enabled || b.client == nil || b.cfg.AdminID == 0 {
		b.running = false
		return
	}
	ctx, cancel := context.WithCancel(b.baseCtx)
	b.pollCancel = cancel
	b.running = true
	client, adminID := b.client, b.cfg.AdminID
	b.pollWG.Add(1)
	go func() {
		defer b.pollWG.Done()
		b.poll(ctx, client, adminID)
	}()
}

// Status отдаёт панели то, что она показывает рядом с формой.
func (b *Bot) Status() Status {
	b.mu.Lock()
	defer b.mu.Unlock()
	return Status{
		Running:     b.running,
		BotUsername: b.username,
		LastError:   b.lastErr,
		MessageID:   b.state.MessageID,
	}
}

// TestConnection проверяет токен и шлёт админу пробное сообщение — кнопка
// «Тест» в панели.
func (b *Bot) TestConnection(ctx context.Context) (string, error) {
	b.mu.Lock()
	client, adminID := b.client, b.cfg.AdminID
	b.mu.Unlock()

	if client == nil {
		return "", ErrNoToken
	}
	me, err := client.GetMe(ctx)
	if err != nil {
		return "", err
	}

	b.mu.Lock()
	b.username = me.Username
	b.mu.Unlock()

	if adminID == 0 {
		return me.Username, ErrNoAdmin
	}
	if _, err := client.SendMessage(ctx, adminID, RenderTestMessage(b.now()), nil, false); err != nil {
		return me.Username, err
	}
	return me.Username, nil
}

// ── Воркер ──────────────────────────────────────────────────────────────────

func (b *Bot) worker(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case r := <-b.results:
			b.handleResult(ctx, r)
		case <-b.redraw:
			b.handleRedraw(ctx)
		}
	}
}

func (b *Bot) requestRedraw() {
	select {
	case b.redraw <- struct{}{}:
	default:
	}
}

// handleResult — новый вердикт: обновить память, решить, было ли событие, и
// доставить сообщение.
func (b *Bot) handleResult(ctx context.Context, r *globalping.CheckResult) {
	now := b.now()

	b.mu.Lock()
	failed := r.Error != "" || r.TotalProbes == 0
	if failed {
		// Неудача не обнуляет доступность: последний удачный вердикт остаётся
		// на месте, а рядом появляется объяснение, почему свежих цифр нет.
		b.lastFail = &Failure{Reason: r.Error, At: r.CheckedAt}
		if b.lastFail.Reason == "" {
			b.lastFail.Reason = "ни один зонд не ответил"
		}
		if b.lastFail.At.IsZero() {
			b.lastFail.At = now
		}
	} else {
		b.lastGood = r
		b.lastFail = nil
	}
	decision := Decide(b.state.Alert, r, b.cfg.AlertThreshold, now)
	b.state.Alert = decision.State
	persist := b.deps.Persist
	state := b.state
	b.mu.Unlock()

	if persist != nil {
		if err := persist(state); err != nil {
			log.Printf("[tgbot] не удалось сохранить состояние: %s", err)
		}
	}

	b.deliver(ctx, decision)
}

// handleRedraw перерисовывает сообщение по тому, что уже известно: кнопка
// «Обновить», включение бота, старт панели.
func (b *Bot) handleRedraw(ctx context.Context) {
	b.mu.Lock()
	if b.lastGood == nil && b.deps.Snapshot != nil {
		if snap := b.deps.Snapshot(); snap != nil && snap.Error == "" && snap.TotalProbes > 0 {
			b.lastGood = snap
		}
	}
	st := b.state.Alert
	b.mu.Unlock()

	b.deliver(ctx, Decision{
		Event:      EventNone,
		Prev:       st.LastPct,
		PrevKnown:  st.HasPct,
		AlertSince: st.Since,
		State:      st,
	})
}

// deliver собирает текст и кладёт его в чат: тихой правкой, если ничего не
// случилось, и новым сообщением, если случилось. Правка не даёт звука —
// потому событию и нужна отправка заново.
func (b *Bot) deliver(ctx context.Context, d Decision) {
	b.mu.Lock()
	client, cfg := b.client, b.cfg
	messageID := b.state.MessageID
	view := View{
		Result:         b.lastGood,
		Failure:        b.lastFail,
		Quota:          zeroQuota(b.deps.Quota),
		AutoCheck:      b.deps.AutoCheck == nil || b.deps.AutoCheck(),
		Interval:       b.deps.Interval,
		Banner:         bannerFor(d.Event),
		PrevPercentage: d.Prev,
		PrevKnown:      d.PrevKnown,
		AlertSince:     d.AlertSince,
		Threshold:      cfg.AlertThreshold,
		Now:            b.now(),
	}
	targetFn := b.deps.Target
	b.mu.Unlock()

	if !cfg.Enabled || client == nil || cfg.AdminID == 0 {
		return
	}
	if view.Threshold <= 0 {
		view.Threshold = DefaultThreshold
	}

	// Адрес и IP выясняются здесь, в воркере: это сеть, и в горутине проверки
	// ей делать нечего.
	if targetFn != nil {
		if target, err := targetFn(ctx); err == nil {
			view.Target = target
			view.Host = b.resolver.Describe(ctx, target.Host)
		}
	}

	text := RenderStatus(view)
	kb := keyboard()

	if d.Event == EventNone && messageID != 0 {
		err := client.EditMessageText(ctx, cfg.AdminID, messageID, text, kb)
		if err == nil {
			b.setLastError("")
			return
		}
		if apiErr, ok := asAPIError(err); ok {
			if apiErr.IsNotModified() {
				// Вердикт повторился слово в слово — это норма, а не сбой.
				b.setLastError("")
				return
			}
			if !apiErr.IsMessageGone() {
				b.reportError("правка сообщения", err)
				return
			}
			// Сообщения больше нет — отправляем новое ниже.
			messageID = 0
		} else {
			b.reportError("правка сообщения", err)
			return
		}
	}

	sent, err := client.SendMessage(ctx, cfg.AdminID, text, kb, false)
	if err != nil {
		b.reportError("отправка сообщения", err)
		return
	}
	b.setLastError("")

	b.mu.Lock()
	b.state.MessageID = sent.MessageID
	persist, state := b.deps.Persist, b.state
	b.mu.Unlock()
	if persist != nil {
		if err := persist(state); err != nil {
			log.Printf("[tgbot] не удалось сохранить id сообщения: %s", err)
		}
	}

	// Старое убираем только теперь: если бы удаляли первым, сорвавшаяся
	// отправка оставила бы чат вообще без статуса.
	if messageID != 0 && messageID != sent.MessageID {
		b.retireMessage(ctx, client, cfg.AdminID, messageID)
	}
}

// retireMessage убирает прежнее живое сообщение. Telegram не даёт боту удалять
// свои сообщения старше 48 часов — а панель вполне может проработать двое
// суток без единого события. Что не удалилось, ужимаем в одну строку, чтобы в
// чате не оставалось второго «статуса» с устаревшими цифрами.
func (b *Bot) retireMessage(ctx context.Context, client *Client, chatID int64, messageID int) {
	if err := client.DeleteMessage(ctx, chatID, messageID); err == nil {
		return
	}
	if err := client.EditMessageText(ctx, chatID, messageID, tombstone, nil); err != nil {
		if apiErr, ok := asAPIError(err); ok && (apiErr.IsMessageGone() || apiErr.IsNotModified()) {
			return
		}
		log.Printf("[tgbot] прежнее сообщение осталось в чате: %s", err)
	}
}

func keyboard() *InlineKeyboardMarkup {
	return &InlineKeyboardMarkup{InlineKeyboard: [][]InlineKeyboardButton{{
		{Text: "🔄 Проверить сейчас", CallbackData: callbackCheck},
		{Text: "↻ Обновить", CallbackData: callbackRefresh},
	}}}
}

func zeroQuota(fn func() globalping.QuotaState) globalping.QuotaState {
	if fn == nil {
		return globalping.QuotaState{}
	}
	return fn()
}

func (b *Bot) setLastError(msg string) {
	b.mu.Lock()
	b.lastErr = msg
	b.mu.Unlock()
}

func (b *Bot) reportError(what string, err error) {
	msg := err.Error()
	if apiErr, ok := asAPIError(err); ok && apiErr.IsChatNotFound() {
		msg = "админ ещё не открывал диалог с ботом — напишите ему /start"
	}
	b.setLastError(what + ": " + msg)
	log.Printf("[tgbot] %s: %s", what, msg)
}

// ── Опрос ───────────────────────────────────────────────────────────────────

func (b *Bot) poll(ctx context.Context, client *Client, adminID int64) {
	if me, err := client.GetMe(ctx); err == nil {
		b.mu.Lock()
		b.username = me.Username
		b.mu.Unlock()
	}

	offset := 0
	backoff := pollBackoffMin

	for {
		if ctx.Err() != nil {
			return
		}
		updates, err := client.GetUpdates(ctx, offset)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if apiErr, ok := asAPIError(err); ok {
				switch {
				case apiErr.IsUnauthorized():
					// Дальше опрашивать нечем: токен отозван или неверен.
					b.setLastError("токен бота отклонён Telegram — проверьте его в @BotFather")
					b.mu.Lock()
					b.running = false
					b.mu.Unlock()
					return
				case apiErr.IsConflict():
					b.setLastError("этого бота уже опрашивает другой процесс — токен занят второй панелью")
				case apiErr.RetryAfter > 0:
					backoff = apiErr.RetryAfter
				default:
					b.setLastError("опрос Telegram: " + apiErr.Description)
				}
			} else {
				b.setLastError("опрос Telegram: " + err.Error())
			}

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff *= 2; backoff > pollBackoffMax {
				backoff = pollBackoffMax
			}
			continue
		}

		backoff = pollBackoffMin
		b.setLastError("")
		for _, u := range updates {
			if u.UpdateID >= offset {
				offset = u.UpdateID + 1
			}
			b.handleUpdate(ctx, client, adminID, u)
		}
	}
}

func (b *Bot) handleUpdate(ctx context.Context, client *Client, adminID int64, u Update) {
	switch {
	case u.Message != nil:
		b.handleMessage(ctx, client, adminID, u.Message)
	case u.CallbackQuery != nil:
		b.handleCallback(ctx, client, adminID, u.CallbackQuery)
	}
}

func (b *Bot) handleMessage(ctx context.Context, client *Client, adminID int64, m *Message) {
	if !strings.HasPrefix(strings.TrimSpace(m.Text), "/start") {
		return
	}
	// На /start отвечаем всем, пока админ не задан: иначе оператору неоткуда
	// узнать свой ID — Telegram его нигде не показывает. Как только ID
	// известен, посторонние получают отказ.
	if adminID != 0 && m.Chat.ID != adminID {
		_, _ = client.SendMessage(ctx, m.Chat.ID, "Этот бот обслуживает чужую панель.", nil, true)
		return
	}
	if _, err := client.SendMessage(ctx, m.Chat.ID, RenderStartReply(m.Chat.ID, m.Chat.ID == adminID), nil, false); err != nil {
		log.Printf("[tgbot] ответ на /start не ушёл: %s", err)
	}
}

func (b *Bot) handleCallback(ctx context.Context, client *Client, adminID int64, q *CallbackQuery) {
	if q.From.ID != adminID {
		_ = client.AnswerCallbackQuery(ctx, q.ID, "Эта кнопка не для вас.", true)
		return
	}

	switch q.Data {
	case callbackRefresh:
		_ = client.AnswerCallbackQuery(ctx, q.ID, "Обновляю по последним данным", false)
		b.requestRedraw()

	case callbackCheck:
		if b.deps.RunCheckNow == nil {
			_ = client.AnswerCallbackQuery(ctx, q.ID, "Проверка недоступна.", true)
			return
		}
		// Кулдаун и исчерпанная квота отвечают мгновенно, настоящее измерение
		// идёт десятки секунд. Ждём короткое окно: успели получить отказ —
		// показываем его всплывашкой, не успели — говорим «проверяю», а
		// результат придёт обычным путём и перерисует сообщение сам.
		done := make(chan error, 1)
		go func() {
			_, err := b.deps.RunCheckNow(ctx)
			done <- err
		}()
		select {
		case err := <-done:
			if err != nil {
				_ = client.AnswerCallbackQuery(ctx, q.ID, err.Error(), true)
				return
			}
			_ = client.AnswerCallbackQuery(ctx, q.ID, "Готово", false)
		case <-time.After(fastFailWindow):
			_ = client.AnswerCallbackQuery(ctx, q.ID, "Проверяю — сообщение обновится само", false)
			go func() {
				if err := <-done; err != nil {
					log.Printf("[tgbot] проверка по кнопке не удалась: %s", err)
				}
			}()
		}

	default:
		_ = client.AnswerCallbackQuery(ctx, q.ID, "", false)
	}
}
