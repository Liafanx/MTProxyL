package server

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/geoip"
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

// geoipCache holds the lazily-opened GeoIP database.
//
// The panel runs unprivileged and cannot watch the filesystem for a database
// that shows up after startup — an install triggered from the Addons page
// writes it as root through the CLI, in a separate process. So instead of
// opening once at startup, every lookup re-resolves the candidate paths until
// one succeeds, then caches the result.
var geoipCache struct {
	mu     sync.Mutex
	lookup *geoip.Lookup
}

// getGeoIPLookup returns the current database, opening it on first success.
func getGeoIPLookup(cfg *config.Config) *geoip.Lookup {
	geoipCache.mu.Lock()
	defer geoipCache.mu.Unlock()
	if geoipCache.lookup != nil {
		return geoipCache.lookup
	}

	dbPath, asnPath := cfg.GeoIP.DBPath, cfg.GeoIP.ASNDBPath
	if dbPath == "" {
		dbPath, asnPath = config.ResolveGeoIPPaths(cfg.DataDir)
		if dbPath == "" {
			return nil
		}
	}

	l, err := geoip.New(dbPath, asnPath)
	if err != nil {
		log.Printf("WARNING: failed to open GeoIP database at %s: %s", dbPath, err)
		return nil
	}
	log.Printf("GeoIP: database loaded from %s", dbPath)
	geoipCache.lookup = l
	return l
}

// invalidateGeoIPLookup is called after `geoip install` completes, so the
// next lookup notices the freshly-downloaded database immediately instead of
// waiting for whatever triggered the previous failed resolution to retry.
func invalidateGeoIPLookup() {
	geoipCache.mu.Lock()
	defer geoipCache.mu.Unlock()
	geoipCache.lookup = nil
}

// writeCLIError maps a bridge failure onto an HTTP response.
func writeCLIError(w http.ResponseWriter, code string, err error) {
	if errors.Is(err, mtproxylctl.ErrDisabled) {
		writeError(w, http.StatusServiceUnavailable, "mtproxyl_disabled",
			"Интеграция с MTProxyL отключена в конфигурации панели")
		return
	}
	writeError(w, http.StatusBadGateway, code, err.Error())
}

// ConfigEditTarget says how the panel should edit the engine's configuration
// and which file that is.
type ConfigEditTarget struct {
	// Mode is "api" or "file".
	Mode string
	// Path is the file to edit in file mode; empty in api mode.
	Path string
	// ForcedByMode is set when reanimator mode overrode the configured value,
	// so the UI can explain why it is not editing through the API.
	ForcedByMode bool
	// Reanimator marks the file as the foreign target's. It belongs to that
	// target, not to the panel, so it is read and written through MTProxyL
	// rather than directly: the panel runs unprivileged and a systemd target
	// keeps its config where only its own user may look.
	Reanimator bool
}

// resolveConfigEditTarget picks between editing the engine's config file and
// patching it through the engine's API.
//
// In reanimator mode the file always wins, whatever config_edit_mode says. The
// API reports the engine's *effective* configuration — every factory default
// included — so a save writes hundreds of values the operator never typed and
// freezes them at today's defaults. That is precisely what MTProxyL must not do
// to a config it does not own: in reanimator mode it edits the target's file
// and touches nothing else.
//
// The path also comes from MTProxyL there: it detected the target and knows
// where its config lives, while the panel's own telemt.config_path points at
// whatever was configured at install time.
func resolveConfigEditTarget(ctx context.Context, cfg config.TelemtConfig, c *mtproxylctl.Client) ConfigEditTarget {
	configured := ConfigEditTarget{Mode: cfg.EffectiveConfigEditMode()}
	if configured.Mode == "file" {
		configured.Path = cfg.ConfigPath
	}
	if c == nil || !c.Enabled() {
		return configured
	}
	st, err := cachedMode(ctx, c)
	if err != nil || st == nil || st.Mode != mtproxylctl.ModeReanimator {
		return configured
	}
	path := st.EngineConfig
	if path == "" {
		path = st.DetectedConfig
	}
	if path == "" {
		// Цель есть, а её конфиг не найден — навязывать файловый режим без
		// пути нельзя, редактор просто не откроется.
		return configured
	}
	return ConfigEditTarget{
		Mode:         "file",
		Path:         path,
		ForcedByMode: cfg.EffectiveConfigEditMode() != "file",
		Reanimator:   true,
	}
}
