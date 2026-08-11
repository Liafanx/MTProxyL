package globalping

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
)

// fakeGlobalping отвечает на оба запроса проверки сразу готовым измерением:
// статус не «in-progress», поэтому AwaitMeasurement возвращается с первого
// опроса и тест не ждёт реальных пауз.
func fakeGlobalping(t *testing.T, m *Measurement) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost {
			_ = json.NewEncoder(w).Encode(MeasurementCreateResponse{ID: m.ID, ProbesCount: len(m.Results)})
			return
		}
		_ = json.NewEncoder(w).Encode(m)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func newTestChecker(t *testing.T, target Target, targetErr error) *Checker {
	t.Helper()
	return NewChecker("", func(context.Context) (Target, error) {
		return target, targetErr
	}, time.Hour, 1)
}

// collectResults подписывается и возвращает то, что подписчику пришло.
func collectResults(c *Checker) (*[]*CheckResult, *sync.Mutex) {
	var mu sync.Mutex
	got := make([]*CheckResult, 0, 2)
	c.SetOnResult(func(r *CheckResult) {
		mu.Lock()
		got = append(got, r)
		mu.Unlock()
	})
	return &got, &mu
}

func TestCheckerNotifiesSubscriberOnSuccess(t *testing.T) {
	c := newTestChecker(t, Target{Host: "example.com", Port: 443, SNI: "example.com"}, nil)
	srv := fakeGlobalping(t, &Measurement{
		ID:     "m-1",
		Status: "finished",
		Results: []ProbeResult{
			{Probe: Probe{City: "Moscow"}, Result: Result{Status: "finished", TLS: &TLSInfo{}}},
			{Probe: Probe{City: "Kazan"}, Result: Result{Status: "failed", RawOutput: "connection refused"}},
		},
	})
	c.client.baseURL = srv.URL

	got, mu := collectResults(c)

	result, err := c.RunCheckNow(context.Background())
	if err != nil {
		t.Fatalf("RunCheckNow: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(*got) != 1 {
		t.Fatalf("подписчик получил %d уведомлений, ожидалось 1", len(*got))
	}
	if (*got)[0] != result {
		t.Error("подписчику пришёл не тот результат, что вернула проверка")
	}
	if (*got)[0].SuccessProbes != 1 || (*got)[0].TotalProbes != 2 {
		t.Errorf("результат = %d/%d зондов, ожидалось 1/2", (*got)[0].SuccessProbes, (*got)[0].TotalProbes)
	}
}

// Неудачная проверка обязана дойти до подписчика: иначе его сообщение молча
// замрёт на прошлых цифрах и будет выдавать их за свежие.
func TestCheckerNotifiesSubscriberOnFailure(t *testing.T) {
	c := newTestChecker(t, Target{}, errors.New("некуда стучаться"))

	got, mu := collectResults(c)

	if _, err := c.RunCheckNow(context.Background()); err == nil {
		t.Fatal("RunCheckNow вернул успех, хотя цель не определилась")
	}

	mu.Lock()
	defer mu.Unlock()
	if len(*got) != 1 {
		t.Fatalf("подписчик получил %d уведомлений, ожидалось 1", len(*got))
	}
	failed := (*got)[0]
	if failed.Error == "" {
		t.Error("в уведомлении о неудаче нет описания ошибки")
	}
	if !strings.Contains(failed.Error, "некуда стучаться") {
		t.Errorf("Error = %q, ожидалась причина от провайдера цели", failed.Error)
	}
	if failed.TotalProbes != 0 {
		t.Errorf("TotalProbes = %d, ожидалось 0: измерения не было", failed.TotalProbes)
	}
}

// Отказ по квоте — не результат: измерения не было, прошлый вердикт в силе,
// и подписчику сообщать нечего.
func TestCheckerDoesNotNotifyOnRateLimit(t *testing.T) {
	c := newTestChecker(t, Target{Host: "example.com", Port: 443}, nil)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-RateLimit-Reset", "600")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	t.Cleanup(srv.Close)
	c.client.baseURL = srv.URL

	got, mu := collectResults(c)

	_, err := c.RunCheckNow(context.Background())
	var rle *RateLimitError
	if !errors.As(err, &rle) {
		t.Fatalf("ожидалась RateLimitError, получено: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(*got) != 0 {
		t.Errorf("подписчик получил %d уведомлений, ожидалось 0", len(*got))
	}
}

// Без подписчика проверка работает как раньше — эта ветка выполняется у всех,
// кто не включал телеграм-бота.
func TestCheckerWithoutSubscriberDoesNotPanic(t *testing.T) {
	c := newTestChecker(t, Target{}, errors.New("некуда стучаться"))
	if _, err := c.RunCheckNow(context.Background()); err == nil {
		t.Fatal("RunCheckNow вернул успех, хотя цель не определилась")
	}
}
