package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// FrontStatus — `mtproxyl front status --json`: кто держит заглушку
// Selfmask и публичный TLS WEB Proxy.
type FrontStatus struct {
	Server     string   `json:"server"`
	Title      string   `json:"title"`
	Source     string   `json:"source"`
	Service    string   `json:"service"`
	Active     bool     `json:"active"`
	Custom     bool     `json:"custom"`
	CustomFile string   `json:"custom_file"`
	Choices    []string `json:"choices"`
}

// ErrFrontUnsupported — установленный MTProxyL старше 1.7.0.
var ErrFrontUnsupported = fmt.Errorf("MTProxyL без выбора держателя заглушки")

func (c *Client) FrontStatus(ctx context.Context) (*FrontStatus, error) {
	out, err := c.run(ctx, "front", "status", "--json")
	if err != nil {
		if strings.Contains(err.Error(), "Неизвестная команда") || strings.Contains(err.Error(), "not allowed") {
			return nil, ErrFrontUnsupported
		}
		return nil, err
	}
	var st FrontStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, ErrFrontUnsupported
	}
	return &st, nil
}

// SetFront переносит заглушку на nginx, Caddy или HAProxy. Может ставить
// сборку, поэтому идёт через фоновый runner.
func (c *Client) SetFront(ctx context.Context, server string) (string, error) {
	switch server {
	case "nginx", "caddy", "haproxy":
	default:
		return "", fmt.Errorf("держатель: nginx, caddy или haproxy")
	}
	out, err := c.run(ctx, "front", "set", server)
	return stripANSI(out), err
}

// SetWebFrontend выбирает, кто принимает публичный WEB: держатель MTProxyL
// (nginx, caddy, haproxy) или внешний HAProxy (external, external-nginx).
func (c *Client) SetWebFrontend(ctx context.Context, choice string) (string, error) {
	switch choice {
	case "nginx", "caddy", "haproxy", "external", "external-nginx":
	default:
		return "", fmt.Errorf("frontend: nginx, caddy, haproxy, external или external-nginx")
	}
	out, err := c.run(ctx, "web", "frontend", choice)
	return stripANSI(out), err
}

// APIStatus — `mtproxyl api status --json`.
type APIStatus struct {
	Enabled   bool   `json:"enabled"`
	Active    bool   `json:"active"`
	Installed bool   `json:"installed"`
	HasKey    bool   `json:"has_key"`
	Listen    string `json:"listen"`
	Allow     string `json:"allow"`
	TLS       string `json:"tls"`
	URL       string `json:"url"`
	Version   string `json:"version"`
}

func (c *Client) APIStatus(ctx context.Context) (*APIStatus, error) {
	out, err := c.run(ctx, "api", "status", "--json")
	if err != nil {
		return nil, err
	}
	var st APIStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse api status: %w", err)
	}
	return &st, nil
}

// APIToggle включает или выключает службу API. Возвращает новый ключ, если
// он был создан при включении.
func (c *Client) APIToggle(ctx context.Context, on bool) (string, string, error) {
	arg := "off"
	if on {
		arg = "on"
	}
	out, err := c.run(ctx, "api", arg)
	out = stripANSI(out)
	return out, extractAPIKey(out), err
}

// APIRotateKey выдаёт новый ключ; прежний сразу перестаёт действовать.
func (c *Client) APIRotateKey(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "api", "key")
	if err != nil {
		return "", err
	}
	key := extractAPIKey(stripANSI(out))
	if key == "" {
		return "", fmt.Errorf("ключ не получен")
	}
	return key, nil
}

var apiKeyRe = regexp.MustCompile(`(?m)^\s*([0-9a-f]{64})\s*$`)

func extractAPIKey(out string) string {
	if m := apiKeyRe.FindStringSubmatch(out); m != nil {
		return m[1]
	}
	return ""
}

var (
	apiListenRe = regexp.MustCompile(`^(\[[0-9a-fA-F:]+\]|[0-9.]+):[0-9]{1,5}$`)
	apiAllowRe  = regexp.MustCompile(`^[0-9a-fA-F:.,/ ]*$`)
)

// APISet меняет API_LISTEN, API_ALLOW или API_TLS.
func (c *Client) APISet(ctx context.Context, key, value string) (string, error) {
	switch key {
	case "API_LISTEN":
		if !apiListenRe.MatchString(value) {
			return "", fmt.Errorf("адрес: IP:порт, например 0.0.0.0:9190")
		}
	case "API_ALLOW":
		if !apiAllowRe.MatchString(value) {
			return "", fmt.Errorf("адреса: IP или CIDR через запятую")
		}
		value = strings.ReplaceAll(value, " ", "")
		if value == "" {
			value = "-"
		}
	case "API_TLS":
		if value != "off" && value != "selfmask" {
			return "", fmt.Errorf("HTTPS: off или selfmask")
		}
	default:
		return "", fmt.Errorf("неизвестный параметр %s", key)
	}
	out, err := c.run(ctx, "api", "set", key, value)
	return stripANSI(out), err
}
