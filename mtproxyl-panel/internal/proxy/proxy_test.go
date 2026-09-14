package proxy

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestReverseProxyStopsWaitingForTelemtHeaders(t *testing.T) {
	telemt := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer telemt.Close()

	p, err := newTelemtProxy(telemt.URL, "", 75*time.Millisecond)
	if err != nil {
		t.Fatalf("newTelemtProxy: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/telemt/v1/health", nil)
	rec := httptest.NewRecorder()
	started := time.Now()
	p.ServeHTTP(rec, req)

	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("reverse proxy remained blocked for %s", elapsed)
	}
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadGateway)
	}
	var body struct {
		OK    bool `json:"ok"`
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response JSON: %v", err)
	}
	if body.OK || body.Error.Code != "bad_gateway" {
		t.Fatalf("unexpected response: %s", rec.Body.String())
	}
}

func TestGetSystemInfoHasTotalTimeout(t *testing.T) {
	telemt := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer telemt.Close()

	p, err := newTelemtProxy(telemt.URL, "", 75*time.Millisecond)
	if err != nil {
		t.Fatalf("newTelemtProxy: %v", err)
	}
	started := time.Now()
	if _, err := p.GetSystemInfo(); err == nil {
		t.Fatal("GetSystemInfo unexpectedly succeeded")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("GetSystemInfo remained blocked for %s", elapsed)
	}
}

func TestReverseProxyStopsStalledTelemtBody(t *testing.T) {
	telemt := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer telemt.Close()

	p, err := newTelemtProxy(telemt.URL, "", 75*time.Millisecond)
	if err != nil {
		t.Fatalf("newTelemtProxy: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/telemt/v1/stats", nil)
	rec := httptest.NewRecorder()
	started := time.Now()
	p.ServeHTTP(rec, req)
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("stalled response body remained blocked for %s", elapsed)
	}
}
