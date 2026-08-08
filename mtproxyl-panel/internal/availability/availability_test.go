package availability

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseNodeResultSuccess(t *testing.T) {
	var res NodeResult
	parseNodeResult(json.RawMessage(`[{"address":"1.1.1.1","time":0.001993}]`), &res)
	if !res.OK {
		t.Fatalf("успешная попытка должна быть OK, получено %+v", res)
	}
	if res.TimeMS != 1 {
		t.Errorf("time_ms = %d, ожидалось 1", res.TimeMS)
	}
}

func TestParseNodeResultError(t *testing.T) {
	var res NodeResult
	parseNodeResult(json.RawMessage(`[{"error":"Connection timed out"}]`), &res)
	if res.OK {
		t.Fatal("попытка с error не должна быть OK")
	}
	// Формулировка узла сохраняется как есть: по ней видно, отфильтрован порт
	// или закрыт.
	if res.Error != "Connection timed out" {
		t.Errorf("error = %q", res.Error)
	}
}

func TestParseNodeResultGarbage(t *testing.T) {
	for _, in := range []string{`[]`, `{}`, `"nope"`} {
		var res NodeResult
		parseNodeResult(json.RawMessage(in), &res)
		if res.OK || res.Error == "" {
			t.Errorf("на %s ожидалась ошибка, получено %+v", in, res)
		}
	}
}

func TestValidateTarget(t *testing.T) {
	ok := []struct {
		host string
		port int
	}{
		{"1.2.3.4", 443},
		{"proxy.example.com", 8443},
		{"my-host_1.example", 1},
	}
	for _, c := range ok {
		if err := ValidateTarget(c.host, c.port); err != nil {
			t.Errorf("ValidateTarget(%q, %d) = %v, ожидалось nil", c.host, c.port, err)
		}
	}

	bad := []struct {
		host string
		port int
	}{
		{"", 443},
		{"1.2.3.4", 0},
		{"1.2.3.4", 70000},
		{"2001:db8::1", 443},       // IPv6 сервис проверки не принимает
		{"host with space", 443},   // ушло бы в URL как есть
		{"evil.example/../x", 443}, // не имя хоста
		{strings.Repeat("a", 300), 443},
	}
	for _, c := range bad {
		if err := ValidateTarget(c.host, c.port); err == nil {
			t.Errorf("ValidateTarget(%q, %d) прошёл, ожидалась ошибка", c.host, c.port)
		}
	}
}

// fakeService повторяет ответы check-host.net в том виде, в каком они приходят
// на самом деле (проверено запросами к живому сервису).
func fakeService(t *testing.T, result string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/check-tcp"):
			_, _ = w.Write([]byte(`{"ok":1,"request_id":"abc","permanent_link":"https://example/report",` +
				`"nodes":{"ru1.node":["ru","Russia","Moscow","1.2.3.4","AS1"],` +
				`"de1.node":["de","Germany","Berlin","5.6.7.8","AS2"]}}`))
		case strings.HasPrefix(r.URL.Path, "/check-result/"):
			_, _ = w.Write([]byte(result))
		default:
			http.NotFound(w, r)
		}
	}))
}

func newTestChecker(base string) *Checker {
	c := NewChecker()
	c.base = base
	c.http = &http.Client{Timeout: 5 * time.Second}
	return c
}

// Полный проход: старт, опрос, сводка. Один узел отвечает, второй — нет.
func TestCheckerFullRun(t *testing.T) {
	srv := fakeService(t, `{"ru1.node":[{"error":"Connection timed out"}],`+
		`"de1.node":[{"address":"5.6.7.8","time":0.05}]}`)
	defer srv.Close()

	c := newTestChecker(srv.URL)
	nodes, id, link, err := c.startRemote(context.Background(), "example.com", 443, 2)
	if err != nil {
		t.Fatalf("startRemote: %v", err)
	}
	if id != "abc" || link == "" || len(nodes) != 2 {
		t.Fatalf("startRemote вернул id=%q link=%q nodes=%d", id, link, len(nodes))
	}
	if nodes["ru1.node"].Country != "Russia" || nodes["ru1.node"].City != "Moscow" {
		t.Errorf("метаданные узла разобраны неверно: %+v", nodes["ru1.node"])
	}

	results, err := c.pollResults(context.Background(), id, nodes)
	if err != nil {
		t.Fatalf("pollResults: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("получено %d результатов, ожидалось 2", len(results))
	}
	// Порядок стабильный: сортировка по коду страны.
	if results[0].CountryCode != "DE" || results[1].CountryCode != "RU" {
		t.Errorf("порядок узлов не по стране: %s, %s", results[0].CountryCode, results[1].CountryCode)
	}
	if !results[0].OK || results[1].OK {
		t.Errorf("итоги узлов неверны: %+v", results)
	}
}

// Узел, который так и не ответил, помечается pending и не идёт в знаменатель:
// «доступен с 1 из 1» честнее, чем «с 1 из 2» из-за молчащего зонда.
func TestSummarizeSkipsPending(t *testing.T) {
	reachable, total := summarize([]NodeResult{
		{Node: "de1.node", OK: true},
		{Node: "ru1.node", Pending: true},
		{Node: "us1.node", Error: "Connection timed out"},
	})
	if total != 2 || reachable != 1 {
		t.Errorf("reachable=%d total=%d, ожидалось 1/2", reachable, total)
	}
}

// Ответ с ok:0 не должен уводить в опрос несуществующей проверки.
func TestStartRemoteRejectsFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"ok":0,"error":"limit exceeded"}`))
	}))
	defer srv.Close()

	c := newTestChecker(srv.URL)
	if _, _, _, err := c.startRemote(context.Background(), "example.com", 443, 2); err == nil {
		t.Fatal("ожидалась ошибка на ok:0")
	} else if !strings.Contains(err.Error(), "limit exceeded") {
		t.Errorf("сообщение сервиса потерялось: %v", err)
	}
}

// Вторая проверка при работающей первой не запускается.
func TestStartRejectsWhileRunning(t *testing.T) {
	c := NewChecker()
	c.report = Report{Phase: PhaseRunning}
	if c.Start("example.com", 443, 2) {
		t.Fatal("Start должен был отказать, пока идёт другая проверка")
	}
}
