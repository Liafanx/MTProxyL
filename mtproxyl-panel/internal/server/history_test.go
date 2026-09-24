package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/history"
)

type stubFetcher struct{ total uint64 }

func (s *stubFetcher) GetJSON(_ context.Context, path string, out any) error {
	var body string
	switch path {
	case "/v1/stats/summary":
		s.total += 10
		body = `{"uptime_seconds":100,"connections_total":` + strconv.FormatUint(s.total, 10) + `,"connections_bad_total":0,"handshake_timeouts_total":0}`
	case "/v1/runtime/connections/summary":
		body = `{"enabled":false}`
	default:
		body = `[]`
	}
	return json.Unmarshal([]byte(body), out)
}

func newHistoryMux(t *testing.T, rec *history.Recorder) *http.ServeMux {
	t.Helper()
	s := New(&config.Config{})
	mux := http.NewServeMux()
	s.registerHistoryRoutes(mux, testJWTSecret, rec)
	return mux
}

func TestHistoryRoute(t *testing.T) {
	rec := history.NewRecorder(&stubFetcher{})
	rec.PollStats(context.Background())
	rec.PollStats(context.Background())
	mux := newHistoryMux(t, rec)

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/history?metric=connections", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated: status %d", w.Code)
	}

	w = httptest.NewRecorder()
	mux.ServeHTTP(w, authedRequest(t, http.MethodGet, "/api/history?metric=connections,available&range=15m", ""))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		OK   bool `json:"ok"`
		Data struct {
			Range  string `json:"range"`
			Series []struct {
				Metric string `json:"metric"`
				State  string `json:"state"`
				Points []struct {
					TS int64   `json:"ts"`
					V  float64 `json:"v"`
				} `json:"points"`
			} `json:"series"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil || !resp.OK {
		t.Fatalf("body: %s", w.Body.String())
	}
	if resp.Data.Range != "15m" || len(resp.Data.Series) != 2 || resp.Data.Series[0].Metric != "connections" {
		t.Fatalf("data = %+v", resp.Data)
	}
	if pts := resp.Data.Series[0].Points; len(pts) != 1 || pts[0].V != 10 {
		t.Fatalf("same-second polls must collapse into one point: %+v", pts)
	}

	for _, target := range []string{"/api/history", "/api/history?metric=nope", "/api/history?metric=connections&range=9d"} {
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, authedRequest(t, http.MethodGet, target, ""))
		if w.Code != http.StatusBadRequest {
			t.Fatalf("%s: status %d", target, w.Code)
		}
	}

	w = httptest.NewRecorder()
	newHistoryMux(t, nil).ServeHTTP(w, authedRequest(t, http.MethodGet, "/api/history?metric=connections", ""))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("disabled: status %d", w.Code)
	}
}
