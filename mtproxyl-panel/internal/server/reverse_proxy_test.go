package server

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRequestIsHTTPS(t *testing.T) {
	tests := []struct {
		name       string
		remoteAddr string
		proto      string
		tls        bool
		want       bool
	}{
		{name: "direct TLS", remoteAddr: "198.51.100.10:1234", tls: true, want: true},
		{name: "local IPv4 proxy", remoteAddr: "127.0.0.1:4321", proto: "https", want: true},
		{name: "local IPv6 proxy", remoteAddr: "[::1]:4321", proto: "HTTPS", want: true},
		{name: "forwarded chain", remoteAddr: "127.0.0.1:4321", proto: "https, http", want: true},
		{name: "local plain HTTP", remoteAddr: "127.0.0.1:4321", proto: "http", want: false},
		{name: "public spoof ignored", remoteAddr: "198.51.100.10:1234", proto: "https", want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "http://panel.test/", nil)
			req.RemoteAddr = tc.remoteAddr
			req.Header.Set("X-Forwarded-Proto", tc.proto)
			if tc.tls {
				req.TLS = &tls.ConnectionState{}
			}
			if got := requestIsHTTPS(req); got != tc.want {
				t.Fatalf("requestIsHTTPS() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestSecurityHeadersBehindLocalHTTPSProxy(t *testing.T) {
	handler := securityHeaders(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodGet, "http://panel.test/", nil)
	req.RemoteAddr = "127.0.0.1:4321"
	req.Header.Set("X-Forwarded-Proto", "https")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("Strict-Transport-Security"); got == "" {
		t.Fatal("Strict-Transport-Security is missing behind trusted local HTTPS proxy")
	}
}
