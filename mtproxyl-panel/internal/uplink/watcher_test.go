package uplink

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeTelemt поднимает подставной API движка. Обработчик получает путь
// эндпоинта, чтобы тест отвечал по-разному на разные запросы.
func fakeTelemt(t *testing.T, handler func(path string, w http.ResponseWriter)) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		handler(r.URL.Path, w)
	}))
	t.Cleanup(srv.Close)
	return NewClient(srv.URL, "")
}

func ok(w http.ResponseWriter, data string) {
	_, _ = w.Write([]byte(`{"ok":true,"data":` + data + `}`))
}

// healthyEngine — минимальный набор ответов для «движок жив».
func healthyEngine(path string, w http.ResponseWriter) bool {
	switch path {
	case "/v1/health":
		ok(w, `{"status":"ok","read_only":false}`)
		return true
	case "/v1/system/info":
		ok(w, `{"version":"1.2.3","process_started_at_epoch_secs":1000,"uptime_seconds":3600}`)
		return true
	}
	return false
}

// productionDCs — реальный снимок с работающего сервера: покрытие по
// дата-центрам скачет от 0 до 100, у медиа-DC писателей нет вовсе, и при этом
// прокси исправно работает. Если этот снимок когда-нибудь начнёт считаться
// аварией — тревоги посыплются круглосуточно.
const productionDCs = `{"enabled":true,"data":{"counters":{},"route_drops":{},"dc_rtt":[
 {"dc":-203,"rtt_ema_ms":37.7,"alive_writers":3,"required_writers":3,"coverage_pct":100},
 {"dc":-5,"rtt_ema_ms":208.4,"alive_writers":2,"required_writers":3,"coverage_pct":66.7},
 {"dc":-4,"rtt_ema_ms":55.4,"alive_writers":4,"required_writers":3,"coverage_pct":100},
 {"dc":-3,"rtt_ema_ms":null,"alive_writers":0,"required_writers":3,"coverage_pct":0},
 {"dc":-2,"rtt_ema_ms":54.0,"alive_writers":18,"required_writers":3,"coverage_pct":100},
 {"dc":-1,"rtt_ema_ms":143.8,"alive_writers":2,"required_writers":3,"coverage_pct":66.7},
 {"dc":1,"rtt_ema_ms":141.9,"alive_writers":19,"required_writers":3,"coverage_pct":100},
 {"dc":2,"rtt_ema_ms":null,"alive_writers":1,"required_writers":3,"coverage_pct":33.3},
 {"dc":3,"rtt_ema_ms":143.8,"alive_writers":1,"required_writers":3,"coverage_pct":33.3},
 {"dc":4,"rtt_ema_ms":52.8,"alive_writers":6,"required_writers":10,"coverage_pct":60},
 {"dc":5,"rtt_ema_ms":207.6,"alive_writers":7,"required_writers":3,"coverage_pct":100},
 {"dc":203,"rtt_ema_ms":48.0,"alive_writers":2,"required_writers":3,"coverage_pct":66.7}]}}`

func newTestWatcher(c *Client) *Watcher {
	return NewWatcher(c, time.Minute, func() float64 { return DefaultFailRateThreshold })
}

// Главный тест этой фичи: боевое состояние сервера не должно объявляться
// аварией, сколько бы ни скакало покрытие отдельных дата-центров.
func TestProductionSnapshotIsNotAnIncident(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		switch path {
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		case "/v1/runtime/upstream_quality":
			ok(w, `{"enabled":true,"counters":{"connect_attempt_total":123488,"connect_success_total":123417,"connect_fail_total":47}}`)
		}
	})

	st := newTestWatcher(c).Poll(context.Background())

	if st.Bad() {
		t.Fatalf("боевой снимок объявлен аварией: %v", st.Problems)
	}
	if st.AliveWriters != 65 || st.RequiredWriters != 43 {
		t.Errorf("писатели = %d/%d, ожидалось 65/43 — это те же числа, что панель "+
			"показывает в сводке «Писатели ME»", st.AliveWriters, st.RequiredWriters)
	}
	if len(st.DCs) != 12 {
		t.Errorf("дата-центров = %d, ожидалось 12", len(st.DCs))
	}
	if st.Level != LevelGreen {
		t.Errorf("Level = %s, ожидался green", st.Level)
	}
}

func TestEmptyWriterPoolIsRed(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, `{"enabled":true,"data":{"dc_rtt":[
			 {"dc":1,"rtt_ema_ms":null,"alive_writers":0,"required_writers":3,"coverage_pct":0},
			 {"dc":2,"rtt_ema_ms":null,"alive_writers":0,"required_writers":3,"coverage_pct":0}]}}`)
		}
	})

	st := newTestWatcher(c).Poll(context.Background())

	if !st.Bad() {
		t.Fatal("пустой пул писателей не объявлен аварией")
	}
	if st.Level != LevelRed {
		t.Errorf("Level = %s, ожидался red", st.Level)
	}
	if !strings.Contains(st.Problems[0], "не может писать в Telegram") {
		t.Errorf("причина = %q", st.Problems[0])
	}
}

func TestIncompleteWriterPoolIsYellow(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, `{"enabled":true,"data":{"dc_rtt":[
			 {"dc":1,"rtt_ema_ms":10,"alive_writers":1,"required_writers":3,"coverage_pct":33}]}}`)
		}
	})

	w := newTestWatcher(c)

	// Одиночный неполный пул — не авария: под наплывом клиентов движок
	// поднимает целевое число писателей, и живые догоняют цель не мгновенно.
	if st := w.Poll(context.Background()); st.Bad() {
		t.Fatalf("расширение пула объявлено аварией с первого опроса: %v", st.Problems)
	}
	w.Poll(context.Background())
	st := w.Poll(context.Background())

	if !st.Bad() || st.Level != LevelYellow {
		t.Fatalf("устойчиво неполный пул: Bad=%v Level=%s, ожидалось true/yellow", st.Bad(), st.Level)
	}
}

// Ровно тот случай, который зашумил боевой прогон на нагруженном прокси:
// пул расширяется под нагрузку, живые писатели догоняют цель за минуту-две.
// Тревоги быть не должно вообще.
func TestPoolCatchingUpUnderLoadIsNotAnIncident(t *testing.T) {
	alive := 6
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, `{"enabled":true,"data":{"dc_rtt":[
			 {"dc":4,"rtt_ema_ms":52,"alive_writers":`+itoa(int64(alive))+`,"required_writers":10,"coverage_pct":60}]}}`)
		}
	})
	w := newTestWatcher(c)

	// Две минуты пул догоняет…
	if st := w.Poll(context.Background()); st.Bad() {
		t.Fatalf("тревога на первой минуте расширения пула: %v", st.Problems)
	}
	alive = 8
	if st := w.Poll(context.Background()); st.Bad() {
		t.Fatalf("тревога на второй минуте расширения пула: %v", st.Problems)
	}
	// …и догнал.
	alive = 10
	st := w.Poll(context.Background())
	if st.Bad() {
		t.Errorf("тревога после того, как пул догнал цель: %v", st.Problems)
	}
	if st.ShortPolls != 0 {
		t.Errorf("ShortPolls = %d, серия должна была оборваться", st.ShortPolls)
	}
}

// Middle proxy не используется — это не авария, а «судить не о чем».
func TestMiddleProxyDisabledIsNotAnIncident(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, `{"enabled":false,"reason":"middle proxy disabled"}`)
		}
	})

	st := newTestWatcher(c).Poll(context.Background())

	if st.Applicable {
		t.Error("Applicable = true при выключенном middle proxy")
	}
	if st.Bad() {
		t.Errorf("выключенный middle proxy объявлен аварией: %v", st.Problems)
	}
	if st.NotApplicableReason == "" {
		t.Error("не сказано, почему судить не о чем")
	}
	if !st.EngineUp {
		t.Error("движок ошибочно объявлен упавшим")
	}
}

// Ловушка, в которую легко попасть: ok:false в конверте — это «не смогли
// узнать», а не «функция выключена». Перепутать значит объявить отключение
// middle proxy при обычном сбое движка.
func TestEnvelopeErrorIsNotMiddleProxyDisabled(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"internal","message":"boom"}}`))
		}
	})

	st := newTestWatcher(c).Poll(context.Background())

	if st.NotApplicableReason != "" {
		t.Errorf("сбой запроса принят за выключенный middle proxy: %q", st.NotApplicableReason)
	}
	if st.EngineError == "" {
		t.Error("сбой запроса не отражён в EngineError")
	}
	if st.Bad() {
		t.Errorf("сбой запроса объявлен аварией связи: %v", st.Problems)
	}
}

// Движок не отвечает — это инцидент движка. Состояние связи при этом не
// вычисляется вовсе, иначе одно падение придёт двумя тревогами про одно и то же.
func TestEngineDownDoesNotProduceLinkIncident(t *testing.T) {
	c := NewClient("http://127.0.0.1:1", "") // никто не слушает
	c.http.Timeout = 200 * time.Millisecond

	w := newTestWatcher(c)
	st := w.Poll(context.Background())

	if st.EngineUp {
		t.Error("EngineUp = true при недоступном движке")
	}
	// Один сорвавшийся опрос — ещё не авария: движок перезапускается за
	// секунды, и тревожить по своим же плановым действиям незачем.
	if st.EngineBad() {
		t.Error("тревога о движке поднята с первого же сорвавшегося опроса")
	}
	if st.Bad() {
		t.Errorf("падение движка объявлено ещё и аварией связи: %v", st.Problems)
	}
	if st.Applicable {
		t.Error("Applicable = true, хотя данных не получили")
	}

	// А вот когда движок не отвечает несколько опросов подряд — это уже авария.
	w.Poll(context.Background())
	st = w.Poll(context.Background())
	if !st.EngineBad() {
		t.Errorf("после %d сорвавшихся опросов подряд тревоги о движке нет", st.FailedPolls)
	}
	if st.Bad() {
		t.Errorf("падение движка объявлено ещё и аварией связи: %v", st.Problems)
	}
}

// Движок отвечает, а телеметрия связи — нет: сменилась авторизация, версия
// старее нужной, эндпоинт выключен. Без счётчика сорвавшихся опросов такая
// поломка не давала бы ни одной тревоги вообще — наблюдение молча переставало
// бы работать.
func TestBrokenTelemetryWithLiveEngineEventuallyAlerts(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"forbidden","message":"нет доступа"}}`))
		}
	})
	w := newTestWatcher(c)

	if st := w.Poll(context.Background()); st.EngineBad() {
		t.Error("тревога поднята с первого сбоя телеметрии")
	}
	w.Poll(context.Background())
	st := w.Poll(context.Background())

	if !st.EngineBad() {
		t.Error("постоянная поломка телеметрии не дала ни одной тревоги — наблюдение молча умерло")
	}
}

// Успешный опрос обнуляет счётчик: два разрозненных сбоя за час аварией не
// являются.
func TestSuccessfulPollResetsFailureStreak(t *testing.T) {
	broken := true
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if broken && path == "/v1/health" {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"boom"}}`))
			return
		}
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, productionDCs)
		}
	})
	w := newTestWatcher(c)

	w.Poll(context.Background())
	w.Poll(context.Background())
	broken = false
	if st := w.Poll(context.Background()); st.FailedPolls != 0 || st.EngineBad() {
		t.Errorf("успешный опрос не обнулил счётчик: FailedPolls=%d", st.FailedPolls)
	}
	broken = true
	if st := w.Poll(context.Background()); st.EngineBad() {
		t.Error("одиночный сбой после успешного опроса объявлен аварией")
	}
}

func TestReadOnlyEngineIsAnIncident(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		switch path {
		case "/v1/health":
			ok(w, `{"status":"ok","read_only":true}`)
		case "/v1/system/info":
			ok(w, `{"version":"1.2.3","process_started_at_epoch_secs":1000,"uptime_seconds":10}`)
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		}
	})

	st := newTestWatcher(c).Poll(context.Background())

	if !st.EngineBad() {
		t.Error("режим только чтения не считается проблемой движка")
	}
}

// ── Дельты счётчиков ────────────────────────────────────────────────────────

func TestFailRateNeedsTwoSamples(t *testing.T) {
	attempts := uint64(1000)
	fails := uint64(10)
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		switch path {
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		case "/v1/runtime/upstream_quality":
			ok(w, `{"enabled":true,"counters":{"connect_attempt_total":`+utoa(attempts)+
				`,"connect_fail_total":`+utoa(fails)+`}}`)
		}
	})
	w := newTestWatcher(c)

	first := w.Poll(context.Background())
	if first.HasFailRate {
		t.Error("доля ошибок посчитана с первого опроса — сравнивать было не с чем")
	}

	attempts, fails = 1100, 15
	second := w.Poll(context.Background())
	if !second.HasFailRate {
		t.Fatal("доля ошибок не посчитана со второго опроса")
	}
	if second.Attempts != 100 || second.Fails != 5 {
		t.Errorf("дельта = %d попыток / %d неудач, ожидалось 100/5", second.Attempts, second.Fails)
	}
	if second.FailRate < 0.049 || second.FailRate > 0.051 {
		t.Errorf("FailRate = %.4f, ожидалось ~0.05", second.FailRate)
	}
}

// Перезапуск движка обнуляет счётчики. Считать по ним дельту нельзя — вышло бы
// огромное отрицательное окно, а на деле измерения просто не было.
func TestEngineRestartResetsCounterBaseline(t *testing.T) {
	startedAt := int64(1000)
	attempts, fails := uint64(100000), uint64(50)
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		switch path {
		case "/v1/health":
			ok(w, `{"status":"ok","read_only":false}`)
		case "/v1/system/info":
			ok(w, `{"version":"1","process_started_at_epoch_secs":`+itoa(startedAt)+`,"uptime_seconds":10}`)
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		case "/v1/runtime/upstream_quality":
			ok(w, `{"enabled":true,"counters":{"connect_attempt_total":`+utoa(attempts)+
				`,"connect_fail_total":`+utoa(fails)+`}}`)
		}
	})
	w := newTestWatcher(c)

	w.Poll(context.Background()) // знакомство
	w.Poll(context.Background()) // база установлена

	// Движок перезапустился: новая метка старта, счётчики с нуля.
	startedAt, attempts, fails = 2000, 5, 0
	st := w.Poll(context.Background())

	if !st.Restarted {
		t.Error("перезапуск движка не замечен")
	}
	if st.HasFailRate {
		t.Errorf("дельта посчитана через перезапуск: %d/%d", st.Fails, st.Attempts)
	}
	if st.Bad() {
		t.Errorf("перезапуск объявлен аварией связи: %v", st.Problems)
	}
}

// Первое наблюдение метки старта — знакомство, а не перезапуск.
func TestFirstSystemInfoIsNotARestart(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, productionDCs)
		}
	})

	if st := newTestWatcher(c).Poll(context.Background()); st.Restarted {
		t.Error("первый опрос объявлен перезапуском движка")
	}
}

// Тишина на прокси: за интервал не было ни одной попытки. Делить не на что, и
// аварией это не является.
func TestZeroAttemptsIsNotAnIncident(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		switch path {
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		case "/v1/runtime/upstream_quality":
			ok(w, `{"enabled":true,"counters":{"connect_attempt_total":500,"connect_fail_total":9}}`)
		}
	})
	w := newTestWatcher(c)

	w.Poll(context.Background())
	st := w.Poll(context.Background())

	if st.Attempts != 0 {
		t.Fatalf("Attempts = %d, ожидалось 0", st.Attempts)
	}
	if st.Bad() {
		t.Errorf("отсутствие попыток объявлено аварией: %v", st.Problems)
	}
	if st.FailRate != 0 {
		t.Errorf("FailRate = %v при нулевых попытках", st.FailRate)
	}
}

func TestHighFailRateIsAnIncident(t *testing.T) {
	attempts, fails := uint64(1000), uint64(100)
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		switch path {
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		case "/v1/runtime/upstream_quality":
			ok(w, `{"enabled":true,"counters":{"connect_attempt_total":`+utoa(attempts)+
				`,"connect_fail_total":`+utoa(fails)+`}}`)
		}
	})
	w := newTestWatcher(c)

	w.Poll(context.Background())
	attempts, fails = 1100, 180 // 80 неудач на 100 попыток

	// Первый всплеск ошибок — ещё не авария: клиенты массово переподключаются
	// после обрыва, и доля скачет сама по себе.
	if st := w.Poll(context.Background()); st.Bad() {
		t.Fatalf("одиночный всплеск ошибок объявлен аварией: %v", st.Problems)
	}
	attempts, fails = 1200, 260
	w.Poll(context.Background())
	attempts, fails = 1300, 340
	st := w.Poll(context.Background())

	if !st.Bad() {
		t.Fatal("устойчиво высокая доля ошибок не объявлена аварией")
	}
	if !strings.Contains(st.Problems[0], "неудачных подключений") {
		t.Errorf("причина = %q", st.Problems[0])
	}
}

func TestSubscriberGetsEveryVerdict(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, productionDCs)
		}
	})
	w := newTestWatcher(c)

	got := 0
	w.SetOnResult(func(*Status) { got++ })
	w.Poll(context.Background())
	w.Poll(context.Background())

	if got != 2 {
		t.Errorf("подписчик получил %d вердиктов, ожидалось 2", got)
	}
	if w.Snapshot() == nil {
		t.Error("Snapshot пуст после опроса")
	}
}

func utoa(v uint64) string {
	return itoa(int64(v))
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [24]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
