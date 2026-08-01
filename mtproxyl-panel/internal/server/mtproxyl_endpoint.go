package server

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// apiEndpointMismatch reports, in Russian, that the panel is polling a different
// engine than the one the current MTProxyL mode owns — or "" when they agree.
//
// The panel is configured with a single telemt URL at install time. Switching
// between manager and reanimator changes which engine is authoritative, but
// nothing rewrites that URL, so the dashboard can keep serving the previous
// mode's users and traffic as though they belonged to the current one. That is
// silent and convincing, which makes it worth calling out explicitly.
func apiEndpointMismatch(telemtURL string, st *mtproxylctl.ModeStatus) string {
	if st == nil || st.APIPort <= 0 {
		return ""
	}
	if !st.APIEnabled {
		return fmt.Sprintf(
			"В конфиге движка этого режима REST API выключен ([server.api] enabled = false в %s). "+
				"Данные ниже приходят не от него — панель опрашивает %s.",
			st.EngineConfig, displayURL(telemtURL))
	}
	port := portOf(telemtURL)
	if port == 0 || port == st.APIPort {
		return ""
	}
	modeName := "Manager"
	if st.Mode == mtproxylctl.ModeReanimator {
		modeName = "Reanimator"
	}
	return fmt.Sprintf(
		"Панель опрашивает API на порту %d, а движок режима %s слушает на %d (%s). "+
			"Пользователи, трафик и статус ниже относятся к другому движку. "+
			"Поправьте url в /etc/mtproxyl-panel/config.toml и перезапустите панель: "+
			"mtproxyl panel restart",
		port, modeName, st.APIPort, st.EngineConfig)
}

func portOf(raw string) int {
	u, err := url.Parse(raw)
	if err != nil {
		return 0
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err == nil {
			return n
		}
		return 0
	}
	switch u.Scheme {
	case "https":
		return 443
	case "http":
		return 80
	}
	return 0
}

// displayURL trims a URL to host:port for messages.
func displayURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	if host, port, err := net.SplitHostPort(u.Host); err == nil {
		return net.JoinHostPort(host, port)
	}
	return u.Host
}

// modeCache keeps the mode probe from spawning a sudo subprocess on every poll.
//
// The availability probe runs on each page load and every two seconds while an
// operation is in flight; `mtproxyl mode --json` reads and parses config files
// each time. The mode itself only changes through an explicit switch, so a
// short cache costs nothing in accuracy.
var modeCache struct {
	mu   sync.Mutex
	at   time.Time
	val  *mtproxylctl.ModeStatus
	err  error
	busy bool
}

const modeCacheTTL = 3 * time.Second

func cachedMode(ctx context.Context, c *mtproxylctl.Client) (*mtproxylctl.ModeStatus, error) {
	modeCache.mu.Lock()
	if time.Since(modeCache.at) < modeCacheTTL && (modeCache.val != nil || modeCache.err != nil) {
		v, e := modeCache.val, modeCache.err
		modeCache.mu.Unlock()
		return v, e
	}
	modeCache.mu.Unlock()

	st, err := c.GetMode(ctx)

	modeCache.mu.Lock()
	modeCache.at = time.Now()
	modeCache.val, modeCache.err = st, err
	modeCache.mu.Unlock()
	return st, err
}

// invalidateModeCache is called after a mode switch so the next probe re-reads.
func invalidateModeCache() {
	modeCache.mu.Lock()
	modeCache.at = time.Time{}
	modeCache.val, modeCache.err = nil, nil
	modeCache.mu.Unlock()
}
