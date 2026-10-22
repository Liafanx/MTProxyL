package wsorigin

import (
	"net/http/httptest"
	"testing"
)

func TestAllowed(t *testing.T) {
	cases := []struct {
		origin, host, fwd string
		want              bool
	}{
		{"", "a.example", "", true},
		{"https://a.example", "a.example", "", true},
		{"https://a.example:8443", "a.example", "a.example", true},
		{"https://A.example:8443", "a.example:8443", "", true},
		{"http://127.0.0.1:8080", "127.0.0.1:8080", "", true},
		{"http://[::1]:8080", "[::1]:8080", "", true},
		{"https://a.example.evil.com", "a.example", "", false},
		{"https://evil.com", "a.example", "", false},
		{"https://evil.com", "evil.com", "a.example", false},
		{"null", "a.example", "", false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/ws", nil)
		r.Host = c.host
		if c.origin != "" {
			r.Header.Set("Origin", c.origin)
		}
		if c.fwd != "" {
			r.Header.Set("X-Forwarded-Host", c.fwd)
		}
		if got := Allowed(r); got != c.want {
			t.Errorf("origin %q host %q fwd %q: %v, want %v", c.origin, c.host, c.fwd, got, c.want)
		}
	}
}
