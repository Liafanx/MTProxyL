package server

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestLoginClientIPTrustsOnlyLocalProxy(t *testing.T) {
	tests := []struct {
		name       string
		remoteAddr string
		forwarded  string
		want       string
	}{
		{name: "direct client cannot spoof", remoteAddr: "198.51.100.7:4321", forwarded: "203.0.113.99", want: "198.51.100.7"},
		{name: "local proxy", remoteAddr: "127.0.0.1:4321", forwarded: "198.51.100.8", want: "198.51.100.8"},
		{name: "legacy appended chain", remoteAddr: "127.0.0.1:4321", forwarded: "203.0.113.99, 198.51.100.9", want: "198.51.100.9"},
		{name: "IPv6 local proxy", remoteAddr: "[::1]:4321", forwarded: "2001:db8::5", want: "2001:db8::5"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/auth/login", nil)
			req.RemoteAddr = tc.remoteAddr
			req.Header.Set("X-Forwarded-For", tc.forwarded)
			if got := loginClientIP(req); got != tc.want {
				t.Fatalf("loginClientIP = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestLoginRateLimiterReservesConcurrentChecks(t *testing.T) {
	limiter := newLoginRateLimiter()
	const requests = 100
	start := make(chan struct{})
	var allowed atomic.Int32
	var wg sync.WaitGroup
	for range requests {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if limiter.take("127.0.0.1", 5, time.Minute) {
				allowed.Add(1)
			}
		}()
	}
	close(start)
	wg.Wait()

	if got := allowed.Load(); got != 5 {
		t.Fatalf("allowed checks = %d, want 5", got)
	}
	limiter.reset("127.0.0.1")
	if !limiter.take("127.0.0.1", 5, time.Minute) {
		t.Fatal("successful login reset did not release the budget")
	}
}
