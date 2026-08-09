package globalping

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"
)

// ipServices are asked in order until one answers. Several of them because a
// single provider is regularly unreachable from a given host — and an address
// that cannot be determined means no check at all.
var ipServices = []string{
	"https://api.ipify.org",
	"https://ifconfig.me/ip",
	"https://icanhazip.com",
	"https://ipecho.net/plain",
}

// PublicIP asks an outside service what this server's address looks like.
// Deliberately not cached: a changed address (new VPS, floating IP) has to be
// noticed, or the panel keeps checking a server that is no longer ours.
func PublicIP(ctx context.Context) (string, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	for _, url := range ipServices {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			continue
		}
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		if resp.StatusCode != http.StatusOK {
			_ = resp.Body.Close()
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
		_ = resp.Body.Close()
		if err != nil {
			continue
		}
		if ip := strings.TrimSpace(string(body)); ip != "" {
			return ip, nil
		}
	}
	return "", errors.New("ни один сервис определения внешнего IP не ответил")
}
