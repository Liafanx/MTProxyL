package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

var vlessIDRe = regexp.MustCompile(`^[0-9a-f]{8}$`)

// ValidateVlessURI checks the link shape before the CLI sees it. The full
// syntax (Reality keys, transports) is validated by the CLI parser.
func ValidateVlessURI(uri string) error {
	uri = strings.TrimSpace(uri)
	if !strings.HasPrefix(uri, "vless://") {
		return fmt.Errorf("ссылка должна начинаться с vless://")
	}
	if len(uri) > 8192 {
		return fmt.Errorf("ссылка слишком длинная")
	}
	for _, r := range uri {
		if r == '\n' || r == '\r' || r < 0x20 {
			return fmt.Errorf("ссылка содержит управляющие символы")
		}
	}
	return nil
}

// GetVlessStatus returns `mtproxyl vless status --json`: service, core version,
// active link and the masked link list. Passed through as is.
func (c *Client) GetVlessStatus(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "vless", "status", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("vless status: invalid JSON")
	}
	return json.RawMessage(line), nil
}

// VlessOn routes all engine traffic through VLESS. force confirms disabling a
// conflicting exit (WARP, donor, own AWG); allowME confirms turning off the
// middle proxy, which cannot work through a SOCKS5 exit.
func (c *Client) VlessOn(ctx context.Context, force, allowME bool) (string, error) {
	args := []string{"vless", "on"}
	if force {
		args = append(args, "--yes")
	}
	if allowME {
		args = append(args, "--allow-disable-me")
	}
	args = append(args, "--defer-restart")
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

// VlessOff removes the VLESS upstream and stops the service.
func (c *Client) VlessOff(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "vless", "off", "--defer-restart")
	return stripANSI(out), err
}

// VlessTest returns `mtproxyl vless test --json`: exit IP, Telegram and DC.
func (c *Client) VlessTest(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "vless", "test", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("vless test: invalid JSON")
	}
	return json.RawMessage(line), nil
}

// VlessLinkAdd adds a vless:// link. name is optional.
func (c *Client) VlessLinkAdd(ctx context.Context, uri, name string) (string, error) {
	if err := ValidateVlessURI(uri); err != nil {
		return "", err
	}
	args := []string{"vless", "link", "add", strings.TrimSpace(uri)}
	if n := strings.TrimSpace(name); n != "" {
		if len([]rune(n)) > 64 {
			return "", fmt.Errorf("имя: до 64 символов")
		}
		args = append(args, n)
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

// VlessLinkUse makes a link active.
func (c *Client) VlessLinkUse(ctx context.Context, id string) (string, error) {
	id = strings.ToLower(strings.TrimSpace(id))
	if !vlessIDRe.MatchString(id) {
		return "", fmt.Errorf("id ссылки: 8 hex-символов")
	}
	out, err := c.run(ctx, "vless", "link", "use", id)
	return stripANSI(out), err
}

// VlessLinkRemove deletes a link from the list.
func (c *Client) VlessLinkRemove(ctx context.Context, id string) (string, error) {
	id = strings.ToLower(strings.TrimSpace(id))
	if !vlessIDRe.MatchString(id) {
		return "", fmt.Errorf("id ссылки: 8 hex-символов")
	}
	out, err := c.run(ctx, "vless", "link", "remove", id)
	return stripANSI(out), err
}

// VlessSubSet sets the subscription URL and refreshes it.
func (c *Client) VlessSubSet(ctx context.Context, url string) (string, error) {
	url = strings.TrimSpace(url)
	if !strings.HasPrefix(url, "https://") || len(url) > 2048 {
		return "", fmt.Errorf("подписка: только https://")
	}
	out, err := c.run(ctx, "vless", "sub", "set", url)
	return stripANSI(out), err
}

// VlessSubRefresh refreshes the subscription.
func (c *Client) VlessSubRefresh(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "vless", "sub", "refresh")
	return stripANSI(out), err
}

// VlessSubOff removes the subscription and the links imported from it.
func (c *Client) VlessSubOff(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "vless", "sub", "off")
	return stripANSI(out), err
}

// VlessHwid shows or regenerates the device identifier sent with subscription
// requests, or toggles whether it is sent.
func (c *Client) VlessHwid(ctx context.Context, action string) (string, error) {
	switch action {
	case "", "show", "regen", "on", "off":
	default:
		return "", fmt.Errorf("неизвестное действие HWID")
	}
	if action == "" {
		action = "show"
	}
	return c.run(ctx, "vless", "hwid", action)
}

// VlessSubUA sets the User-Agent used for subscription requests.
func (c *Client) VlessSubUA(ctx context.Context, ua string) (string, error) {
	ua = strings.TrimSpace(ua)
	if ua == "" || len(ua) > 200 {
		return "", fmt.Errorf("User-Agent должен быть от 1 до 200 символов")
	}
	return c.run(ctx, "vless", "sub", "ua", ua)
}

// VlessUpdate installs the pinned Xray-core build.
func (c *Client) VlessUpdate(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "vless", "update")
	return stripANSI(out), err
}

// VlessRollback returns to the previous Xray-core build.
func (c *Client) VlessRollback(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "vless", "rollback")
	return stripANSI(out), err
}

// VlessRecover restarts the service and re-applies the route.
func (c *Client) VlessRecover(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "vless", "recover", "--defer-restart")
	return stripANSI(out), err
}
