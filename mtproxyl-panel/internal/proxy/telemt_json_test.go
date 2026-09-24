package proxy

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGetJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			t.Errorf("missing auth header")
		}
		switch r.URL.Path {
		case "/v1/stats/summary":
			w.Write([]byte(`{"ok":true,"data":{"connections_total":42}}`))
		case "/v1/broken":
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(`{"ok":false,"error":{"code":"down","message":"restarting"}}`))
		default:
			w.Write([]byte(`{"ok":false,"error":{"code":"not_found","message":"no"}}`))
		}
	}))
	defer srv.Close()

	p, _ := NewTelemtProxy(srv.URL, "Bearer tok")
	var out struct {
		ConnectionsTotal uint64 `json:"connections_total"`
	}
	if err := p.GetJSON(context.Background(), "/v1/stats/summary", &out); err != nil {
		t.Fatalf("GetJSON: %v", err)
	}
	if out.ConnectionsTotal != 42 {
		t.Fatalf("connections_total = %d, want 42", out.ConnectionsTotal)
	}

	var apiErr *TelemtAPIError
	err := p.GetJSON(context.Background(), "/v1/broken", &out)
	if !errors.As(err, &apiErr) || apiErr.Code != "down" || apiErr.Status != 503 {
		t.Fatalf("broken: err = %v", err)
	}
	err = p.GetJSON(context.Background(), "/v1/missing", &out)
	if !errors.As(err, &apiErr) || apiErr.Code != "not_found" {
		t.Fatalf("missing: err = %v", err)
	}
}
