// Package wsorigin проверяет Origin у WebSocket панели.
package wsorigin

import (
	"net"
	"net/http"
	"net/url"
	"strings"
)

// Allowed сравнивает имя хоста из Origin с Host (X-Forwarded-Host) без порта:
// nginx ($host) и Caddy ({host}) отдают панели Host без порта, а браузер
// на нестандартном порту шлёт его в Origin.
func Allowed(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	host := r.Host
	if fwd := r.Header.Get("X-Forwarded-Host"); fwd != "" {
		host = fwd
	}
	u, err := url.Parse(origin)
	if err != nil || u.Hostname() == "" {
		return false
	}
	return strings.EqualFold(u.Hostname(), hostname(host))
}

func hostname(hostport string) string {
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		return h
	}
	return strings.Trim(hostport, "[]")
}
