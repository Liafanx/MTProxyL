package uplink

import (
	"context"
	"log"
	"sync"
	"time"
)

const (
	// DefaultInterval — как часто спрашивать движок. Данные локальные
	// (127.0.0.1), квот нет, стоимость около нуля, поэтому раз в минуту:
	// обрыв связи с дата-центрами замечается за минуту, а не за пятнадцать,
	// как внешняя проверка доступности.
	DefaultInterval = time.Minute

	// startupDelay даёт движку подняться, если панель и прокси стартуют
	// вместе, — иначе первый же опрос объявил бы аварию на пустом месте.
	startupDelay = 10 * time.Second
)

// counterSnapshot — прошлое показание накопительных счётчиков.
//
// На диск не сохраняется намеренно: после перезапуска панели просто
// пропускается одно сравнение, и это дешевле, чем тащить эти числа через
// миграцию сохранённого состояния.
type counterSnapshot struct {
	taken   bool
	startAt int64 // process_started_at_epoch_secs на момент снимка
	attempt uint64
	fail    uint64
}

// Watcher опрашивает движок в фоне и отдаёт вердикт подписчику.
// Устройство повторяет globalping.Checker: тикер + SetOnResult.
type Watcher struct {
	client    *Client
	interval  time.Duration
	now       func() time.Time
	threshold func() float64

	mu       sync.Mutex
	last     *Status
	prev     counterSnapshot
	onResult func(*Status)
}

func NewWatcher(client *Client, interval time.Duration, threshold func() float64) *Watcher {
	if interval < 10*time.Second {
		interval = DefaultInterval
	}
	if threshold == nil {
		threshold = func() float64 { return DefaultFailRateThreshold }
	}
	return &Watcher{client: client, interval: interval, now: time.Now, threshold: threshold}
}

// SetOnResult подписывает на каждый новый вердикт. Как и у проверки
// доступности, обработчик обязан возвращаться немедленно: он вызывается из
// цикла опроса, и всё долгое задержит следующий тик.
func (w *Watcher) SetOnResult(fn func(*Status)) {
	w.mu.Lock()
	w.onResult = fn
	w.mu.Unlock()
}

// Snapshot отдаёт последний вердикт; nil, если опросов ещё не было.
func (w *Watcher) Snapshot() *Status {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.last
}

func (w *Watcher) Start(ctx context.Context) {
	log.Printf("[uplink] наблюдение за связью с дата-центрами включено: интервал %v", w.interval)

	select {
	case <-ctx.Done():
		return
	case <-time.After(startupDelay):
	}
	w.Poll(ctx)

	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Println("[uplink] наблюдение остановлено")
			return
		case <-ticker.C:
			w.Poll(ctx)
		}
	}
}

// Poll делает один опрос и раздаёт вердикт подписчику.
func (w *Watcher) Poll(ctx context.Context) *Status {
	st := w.collect(ctx)

	w.mu.Lock()
	w.last = st
	fn := w.onResult
	w.mu.Unlock()

	if fn != nil {
		fn(st)
	}
	return st
}

func (w *Watcher) collect(ctx context.Context) *Status {
	st := &Status{CheckedAt: w.now()}

	// Сначала движок: если он не отвечает, о связи с дата-центрами судить
	// нечего, и трогать её состояние нельзя — иначе одно падение движка
	// придёт двумя тревогами про одно и то же.
	health, err := w.client.Health(ctx)
	if err != nil {
		st.EngineError = err.Error()
		st.evaluate(w.threshold())
		return st
	}
	st.EngineUp = health.Status == "ok" || health.Status == ""
	st.EngineReadOnly = health.ReadOnly

	if info, err := w.client.SystemInfo(ctx); err == nil {
		st.Version = info.Version
		st.UptimeSeconds = info.UptimeSeconds
		st.Restarted = w.noteStart(info.ProcessStartedAt)
	}

	me, err := w.client.MeQuality(ctx)
	if err != nil {
		st.EngineError = err.Error()
		st.evaluate(w.threshold())
		return st
	}
	// Здесь и проходит граница, которую нельзя размывать: ошибка запроса уже
	// обработана выше, а enabled=false — это «функция выключена в конфиге
	// движка», то есть судить не о чем.
	if !me.Enabled || me.Data == nil {
		st.Applicable = false
		st.NotApplicableReason = me.Reason
		if st.NotApplicableReason == "" {
			st.NotApplicableReason = "функция выключена в конфиге движка"
		}
		st.evaluate(w.threshold())
		return st
	}

	st.Applicable = true
	st.DCs = me.Data.DCRtt
	st.AliveWriters, st.RequiredWriters = sumWriters(me.Data.DCRtt)

	if up, err := w.client.UpstreamQuality(ctx); err == nil && up.Counters != nil {
		st.Attempts, st.Fails, st.HasFailRate = w.delta(*up.Counters)
		if st.HasFailRate && st.Attempts > 0 {
			st.FailRate = float64(st.Fails) / float64(st.Attempts)
		}
	}

	st.evaluate(w.threshold())
	return st
}

// noteStart запоминает метку запуска движка и сообщает, сменилась ли она.
// Смена означает перезапуск — и она же обнуляет базу счётчиков.
func (w *Watcher) noteStart(startedAt int64) bool {
	if startedAt == 0 {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	prev := w.prev.startAt
	w.prev.startAt = startedAt
	if prev == 0 || prev == startedAt {
		// Первое наблюдение — знакомство, а не перезапуск.
		return false
	}
	// Движок стартовал заново: прежние счётчики к новым отношения не имеют.
	w.prev.taken = false
	return true
}

// delta считает попытки и неудачи за интервал между опросами.
//
// Возвращает ok=false, когда сравнивать не с чем: первый опрос либо счётчики
// оказались меньше прежних (движок перезапустился между опросами). Доля
// считается как отношение, а не «в минуту», поэтому пропущенные опросы её не
// портят: если панель спала двадцать минут, дельта просто посчитается за эти
// двадцать минут.
func (w *Watcher) delta(cur UpstreamCounters) (attempts, fails uint64, ok bool) {
	w.mu.Lock()
	defer w.mu.Unlock()

	prev := w.prev
	w.prev.taken = true
	w.prev.attempt = cur.ConnectAttemptTotal
	w.prev.fail = cur.ConnectFailTotal

	switch {
	case !prev.taken:
		return 0, 0, false
	case cur.ConnectAttemptTotal < prev.attempt || cur.ConnectFailTotal < prev.fail:
		// Счётчики поехали назад — движок перезапустился, окно рвём.
		return 0, 0, false
	}
	return cur.ConnectAttemptTotal - prev.attempt, cur.ConnectFailTotal - prev.fail, true
}
