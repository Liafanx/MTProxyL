package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

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

	rec.WithTrafficStore(history.NewTrafficStore(""))
	rec.PollUsers(context.Background())
	for _, target := range []string{"/api/history/traffic?range=7d", "/api/history/traffic/users/alice?range=24h"} {
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, authedRequest(t, http.MethodGet, target, ""))
		if w.Code != http.StatusOK {
			t.Fatalf("%s: status %d: %s", target, w.Code, w.Body.String())
		}
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, authedRequest(t, http.MethodGet, "/api/history/traffic?range=2y", ""))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("traffic bad range: status %d", w.Code)
	}

	w = httptest.NewRecorder()
	newHistoryMux(t, nil).ServeHTTP(w, authedRequest(t, http.MethodGet, "/api/history?metric=connections", ""))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("disabled: status %d", w.Code)
	}
}

type fingerprintStub struct{ gate string }

func (f *fingerprintStub) GetJSON(_ context.Context, path string, out any) error {
	body := `[]`
	switch {
	case path == "/v1/stats/summary":
		body = `{"uptime_seconds":100,"connections_total":1}`
	case path == "/v1/runtime/connections/summary":
		body = `{"enabled":false}`
	case len(path) > 28 && path[:28] == "/v1/runtime/tls-fingerprints":
		body = f.gate
	}
	return json.Unmarshal([]byte(body), out)
}

func fingerprintSnapshot() string {
	now := time.Now().Unix()
	row := func(scope, ja3, ja4 string, total, auth, bad int) string {
		return fmt.Sprintf(`{"scope":%q,"ja3":%q,"ja3_raw":"","ja4":%q,"ja4_raw":"","total":%d,"auth_success":%d,"bad_or_probe":%d,"first_seen_epoch_secs":%d,"last_seen_epoch_secs":%d}`,
			scope, ja3, ja4, total, auth, bad, now-600, now-60)
	}
	return `{"enabled":true,"data":{"limit":500,"retention_secs":3600,"capacity":4096,"dropped_total":0,"parse_error_total":0,` +
		`"by_fingerprint":[` + row("", "a", "t13d", 7, 7, 0) + `],` +
		`"by_ip":[` + row("1.1.1.1", "a", "t13d", 3, 3, 0) + `,` + row("8.8.8.8", "b", "t13x", 4, 0, 4) + `],"by_cidr":[],"by_user":[]}}`
}

func TestFingerprintRoutes(t *testing.T) {
	stub := &fingerprintStub{gate: fingerprintSnapshot()}
	dir := t.TempDir()
	rec := history.NewRecorder(stub).
		WithTrafficStore(history.NewTrafficStore(dir+"/traffic.json")).
		WithFingerprintStore(history.NewFingerprintStore(dir+"/fp.json")).
		WithLimits(dir+"/limits.json", history.DefaultLimits())
	rec.PollFingerprints(context.Background())
	s := New(&config.Config{DataDir: dir})
	mux := http.NewServeMux()
	s.registerFingerprintRoutes(mux, testJWTSecret, rec, stub)

	type page struct {
		OK   bool `json:"ok"`
		Data struct {
			Source string `json:"source"`
			Total  int    `json:"total"`
			Counts map[string]int
			Rows   []struct {
				Key   string `json:"key"`
				Total int    `json:"total"`
			} `json:"rows"`
			Gate struct{ Enabled bool } `json:"gate"`
		} `json:"data"`
	}
	get := func(target string) page {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, authedRequest(t, http.MethodGet, target, ""))
		if w.Code != http.StatusOK {
			t.Fatalf("%s: status %d: %s", target, w.Code, w.Body.String())
		}
		var p page
		if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
			t.Fatal(err)
		}
		return p
	}
	p := get("/api/history/fingerprints?scope=by_ip&sort=bad_or_probe&order=desc")
	if p.Data.Source != "panel" || p.Data.Total != 2 || p.Data.Rows[0].Key != "8.8.8.8" || !p.Data.Gate.Enabled {
		t.Fatalf("panel page: %+v", p.Data)
	}
	if p = get("/api/history/fingerprints?scope=by_ip&suspicious=1&sort=key&order=asc"); p.Data.Total != 1 || p.Data.Rows[0].Key != "8.8.8.8" {
		t.Fatalf("suspicious: %+v", p.Data)
	}
	if p = get("/api/history/fingerprints?scope=by_ip&q=1.1&limit=1"); p.Data.Total != 1 || p.Data.Counts["by_ip"] != 2 {
		t.Fatalf("search: %+v", p.Data)
	}
	for _, target := range []string{"/api/history/fingerprints?scope=nope", "/api/history/fingerprints?sort=nope", "/api/history/fingerprints?order=up", "/api/history/fingerprints?limit=0"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, authedRequest(t, http.MethodGet, target, ""))
		if w.Code != http.StatusBadRequest {
			t.Fatalf("%s: status %d", target, w.Code)
		}
	}

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, authedRequest(t, http.MethodPut, "/api/history/limits", `{"traffic_max_users":5,"fingerprints_max_records":1,"fingerprints_retention_days":7}`))
	if w.Code != http.StatusOK {
		t.Fatalf("limits: %d %s", w.Code, w.Body.String())
	}
	if l := rec.Limits(); l.FingerprintsMaxRecords != 1 || l.TrafficMaxUsers != 5 {
		t.Fatalf("limits applied: %+v", l)
	}
	if got, _ := history.LoadLimits(dir + "/limits.json"); got.FingerprintsRetentionDays != 7 {
		t.Fatalf("limits saved: %+v", got)
	}
	if p = get("/api/history/fingerprints?scope=by_ip"); p.Data.Total != 1 {
		t.Fatalf("max records must prune: %+v", p.Data)
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, authedRequest(t, http.MethodPut, "/api/history/limits", `{"traffic_max_users":-1}`))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("invalid limits: %d", w.Code)
	}

	w = httptest.NewRecorder()
	mux.ServeHTTP(w, authedRequest(t, http.MethodGet, "/api/history/storage", ""))
	var st struct {
		Data struct {
			Fingerprints struct {
				Enabled bool  `json:"enabled"`
				Records int   `json:"records"`
				Bytes   int64 `json:"bytes"`
			} `json:"fingerprints"`
			Limits history.Limits `json:"limits"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &st); err != nil || !st.Data.Fingerprints.Enabled || st.Data.Fingerprints.Records != 2 || st.Data.Fingerprints.Bytes == 0 || st.Data.Limits.TrafficMaxUsers != 5 {
		t.Fatalf("storage: %s", w.Body.String())
	}

	w = httptest.NewRecorder()
	mux.ServeHTTP(w, authedRequest(t, http.MethodDelete, "/api/history/fingerprints", ""))
	if w.Code != http.StatusOK {
		t.Fatalf("clear: %d %s", w.Code, w.Body.String())
	}
	if p = get("/api/history/fingerprints?scope=by_ip"); p.Data.Total != 0 {
		t.Fatalf("cleared: %+v", p.Data)
	}

	// Хранилище выключено: строки приходят прямо из движка.
	liveMux := http.NewServeMux()
	s.registerFingerprintRoutes(liveMux, testJWTSecret, nil, stub)
	w = httptest.NewRecorder()
	liveMux.ServeHTTP(w, authedRequest(t, http.MethodGet, "/api/history/fingerprints?scope=by_ip", ""))
	var live page
	if err := json.Unmarshal(w.Body.Bytes(), &live); err != nil || live.Data.Source != "engine" || live.Data.Total != 2 {
		t.Fatalf("live: %s", w.Body.String())
	}
	w = httptest.NewRecorder()
	liveMux.ServeHTTP(w, authedRequest(t, http.MethodDelete, "/api/history/traffic", ""))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("clear without store: %d", w.Code)
	}
}
