// Package mtddshim lets the panel work with an mtdd target as it works with
// telemt. Pages, WebSocket subscriptions and the history recorder all speak
// telemt's REST API; mtdd has a different one, and its token is readable only
// by root. When MTProxyL reports engine_kind=mtdd, the shim answers the
// telemt GETs the panel uses from one `mtproxyl target-api snapshot` — one CLI
// call per few seconds for every tab — instead of sending them to the network.
// Users change through MTProxyL's own CLI paths, not through this shim.
package mtddshim

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// Source is what the shim needs from MTProxyL's CLI.
type Source interface {
	GetMode(ctx context.Context) (*mtproxylctl.ModeStatus, error)
	TargetSnapshot(ctx context.Context) ([]byte, error)
	ResetQuota(ctx context.Context, label string) (string, error)
}

const (
	defaultModeTTL     = 30 * time.Second
	defaultSnapshotTTL = 5 * time.Second
	cliTimeout         = 60 * time.Second
)

// Shim decides per request whether the target is mtdd and, if so, serves it.
type Shim struct {
	src         Source
	modeTTL     time.Duration
	snapshotTTL time.Duration
	now         func() time.Time

	modeFetchMu sync.Mutex // one mode probe at a time
	mu          sync.Mutex
	mtdd        bool
	modeKnown   bool // false at start and after Invalidate: the next request waits for the CLI
	modeAt      time.Time
	refreshing  bool
	refreshWG   sync.WaitGroup // background mode refreshes; tests wait on it
	lastModeErr string

	fetchMu sync.Mutex // one snapshot fetch at a time; waiters reuse its result
	snapMu  sync.Mutex
	snap    *snapshot
	snapErr error
	snapAt  time.Time
}

// New returns a shim backed by MTProxyL's CLI.
func New(src Source) *Shim {
	return &Shim{src: src, modeTTL: defaultModeTTL, snapshotTTL: defaultSnapshotTTL, now: time.Now}
}

// snapshot is the output of `mtproxyl target-api snapshot`. Fields stay raw:
// the shim only hands them on in telemt's envelope.
type snapshot struct {
	Users       []json.RawMessage `json:"users"`
	Summary     json.RawMessage   `json:"summary"`
	SystemInfo  json.RawMessage   `json:"system_info"`
	Health      json.RawMessage   `json:"health"`
	Dcs         json.RawMessage   `json:"dcs"`
	ActiveIPs   json.RawMessage   `json:"active_ips"`
	Quota       json.RawMessage   `json:"quota"`
	Connections json.RawMessage   `json:"connections"`
}

// cachedMode returns the last answer, whether it is still fresh, and whether
// there is an answer at all.
func (s *Shim) cachedMode() (v, fresh, known bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.modeKnown {
		return false, false, false
	}
	return s.mtdd, s.now().Sub(s.modeAt) < s.modeTTL, true
}

// Active reports whether the current target is mtdd. A stale answer is
// returned at once and re-read in the background, so a request to telemt
// never waits for the CLI just because the cache expired. Only the first
// request (and the first after Invalidate) waits. On a CLI error the last
// known answer stands (telemt at start).
func (s *Shim) Active(ctx context.Context) bool {
	v, fresh, known := s.cachedMode()
	if fresh {
		return v
	}
	if known {
		s.mu.Lock()
		start := !s.refreshing
		if start {
			s.refreshing = true
			s.refreshWG.Add(1)
		}
		s.mu.Unlock()
		if start {
			go func() {
				defer s.refreshWG.Done()
				s.fetchMode(context.WithoutCancel(ctx))
			}()
		}
		return v
	}
	return s.fetchMode(ctx)
}

func (s *Shim) fetchMode(ctx context.Context) bool {
	s.modeFetchMu.Lock()
	defer s.modeFetchMu.Unlock()
	defer func() {
		s.mu.Lock()
		s.refreshing = false
		s.mu.Unlock()
	}()
	if v, fresh, _ := s.cachedMode(); fresh {
		return v
	}

	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cliTimeout)
	defer cancel()
	st, err := s.src.GetMode(cctx)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.modeAt = s.now()
	s.modeKnown = true
	if err != nil {
		// Раз в 30 с одна и та же ошибка — шум; пишем только новую.
		if err.Error() != s.lastModeErr {
			log.Printf("[mtddshim] mode: %v", err)
			s.lastModeErr = err.Error()
		}
		return s.mtdd
	}
	s.lastModeErr = ""
	if st.IsMtdd() != s.mtdd {
		log.Printf("[mtddshim] target engine: mtdd=%v", st.IsMtdd())
	}
	s.mtdd = st.IsMtdd()
	return s.mtdd
}

// Invalidate drops every cached answer: after a mode switch the target may
// be another engine.
func (s *Shim) Invalidate() {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.modeKnown = false
	s.modeAt = time.Time{}
	s.mu.Unlock()
	s.InvalidateSnapshot()
}

// InvalidateSnapshot drops the cached snapshot after a user change, so the
// next page poll shows it at once rather than after the cache expires.
func (s *Shim) InvalidateSnapshot() {
	if s == nil {
		return
	}
	s.snapMu.Lock()
	s.snapAt = time.Time{}
	s.snapMu.Unlock()
}

func (s *Shim) cached() (*snapshot, error, bool) {
	s.snapMu.Lock()
	defer s.snapMu.Unlock()
	if s.snapAt.IsZero() || s.now().Sub(s.snapAt) >= s.snapshotTTL {
		return nil, nil, false
	}
	return s.snap, s.snapErr, true
}

func (s *Shim) snapshot(ctx context.Context) (*snapshot, error) {
	if sn, err, ok := s.cached(); ok {
		return sn, err
	}
	s.fetchMu.Lock()
	defer s.fetchMu.Unlock()
	if sn, err, ok := s.cached(); ok {
		return sn, err
	}
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cliTimeout)
	defer cancel()
	raw, err := s.src.TargetSnapshot(cctx)
	var sn *snapshot
	if err == nil {
		sn = &snapshot{}
		if jerr := json.Unmarshal(raw, sn); jerr != nil {
			sn, err = nil, fmt.Errorf("target-api snapshot: %w", jerr)
		}
	}
	if err != nil {
		log.Printf("[mtddshim] snapshot: %v", err)
	}
	s.snapMu.Lock()
	s.snap, s.snapErr, s.snapAt = sn, err, s.now()
	s.snapMu.Unlock()
	return sn, err
}

// Wrap returns a RoundTripper that serves mtdd targets itself and passes
// everything else to base unchanged.
func (s *Shim) Wrap(base http.RoundTripper) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return &roundTripper{shim: s, base: base}
}

type roundTripper struct {
	shim *Shim
	base http.RoundTripper
}

func (rt *roundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	if !rt.shim.Active(req.Context()) {
		return rt.base.RoundTrip(req)
	}
	if req.Body != nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(req.Body, 1<<20))
		req.Body.Close()
	}
	status, body := rt.shim.serve(req)
	return &http.Response{
		Status:        fmt.Sprintf("%d %s", status, http.StatusText(status)),
		StatusCode:    status,
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        http.Header{"Content-Type": []string{"application/json"}},
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
		Request:       req,
	}, nil
}

// apiPath cuts the telemt URL's own prefix: the panel may be configured with
// a base path in front of /v1/.
func apiPath(u *url.URL) string {
	p := u.Path
	if i := strings.Index(p, "/v1/"); i >= 0 {
		return p[i:]
	}
	return p
}

func ok(data any) (int, []byte) {
	raw, err := json.Marshal(map[string]any{"ok": true, "data": data})
	if err != nil {
		return fail(http.StatusInternalServerError, "internal", err.Error())
	}
	return http.StatusOK, raw
}

func fail(status int, code, msg string) (int, []byte) {
	raw, _ := json.Marshal(map[string]any{"ok": false, "error": map[string]string{"code": code, "message": msg}})
	return status, raw
}

func notSupported(what string) (int, []byte) {
	return fail(http.StatusNotImplemented, "not_supported_by_mtdd", "У mtdd этого нет: "+what)
}

// gateOff is telemt's shape for a feature switched off, which the pages and
// the recorder already handle.
func gateOff(reason string) (int, []byte) {
	return ok(map[string]any{"enabled": false, "reason": reason, "data": nil})
}

func (s *Shim) serve(req *http.Request) (int, []byte) {
	path := apiPath(req.URL)
	if req.Method != http.MethodGet {
		return s.serveWrite(req, path)
	}
	switch path {
	case "/v1/runtime/tls-fingerprints":
		return gateOff("У mtdd нет TLS-отпечатков")
	case "/v1/runtime/gates":
		return ok(map[string]any{})
	}
	if !knownRead(path) {
		return notSupported(path)
	}
	sn, err := s.snapshot(req.Context())
	if err != nil {
		return fail(http.StatusBadGateway, "mtdd_unavailable", "Цель mtdd не отвечает: "+err.Error())
	}
	switch path {
	case "/v1/users":
		if sn.Users == nil {
			return ok([]json.RawMessage{})
		}
		return ok(sn.Users)
	case "/v1/stats/summary":
		return ok(sn.Summary)
	case "/v1/system/info":
		return ok(sn.SystemInfo)
	case "/v1/health":
		return ok(sn.Health)
	case "/v1/stats/dcs":
		return ok(sn.Dcs)
	case "/v1/stats/users/active-ips":
		return ok(sn.ActiveIPs)
	case "/v1/stats/users/quota":
		return ok(sn.Quota)
	case "/v1/runtime/connections/summary":
		return ok(map[string]any{"enabled": true, "data": map[string]any{"totals": sn.Connections}})
	}
	if name, found := strings.CutPrefix(path, "/v1/users/"); found && !strings.Contains(name, "/") {
		for _, u := range sn.Users {
			var head struct {
				Username string `json:"username"`
			}
			if json.Unmarshal(u, &head) == nil && head.Username == name {
				return ok(u)
			}
		}
		return fail(http.StatusNotFound, "not_found", "Пользователь "+name+" не найден у mtdd")
	}
	return notSupported(path)
}

func knownRead(path string) bool {
	switch path {
	case "/v1/users", "/v1/stats/summary", "/v1/system/info", "/v1/health", "/v1/stats/dcs",
		"/v1/stats/users/active-ips", "/v1/stats/users/quota", "/v1/runtime/connections/summary":
		return true
	}
	name, found := strings.CutPrefix(path, "/v1/users/")
	return found && name != "" && !strings.Contains(name, "/")
}

// serveWrite handles the only write the pages still send to telemt directly
// with an mtdd target — quota reset; user edits already go through MTProxyL.
func (s *Shim) serveWrite(req *http.Request, path string) (int, []byte) {
	if req.Method == http.MethodPost && strings.HasPrefix(path, "/v1/users/") && strings.HasSuffix(path, "/reset-quota") {
		name := strings.TrimSuffix(strings.TrimPrefix(path, "/v1/users/"), "/reset-quota")
		if name == "" || strings.Contains(name, "/") {
			return fail(http.StatusBadRequest, "bad_request", "Не указан пользователь")
		}
		cctx, cancel := context.WithTimeout(context.WithoutCancel(req.Context()), cliTimeout)
		defer cancel()
		if _, err := s.src.ResetQuota(cctx, name); err != nil {
			return fail(http.StatusBadGateway, "mtproxyl_error", err.Error())
		}
		s.InvalidateSnapshot()
		return ok(map[string]any{})
	}
	return fail(http.StatusNotImplemented, "not_supported_by_mtdd",
		"Цель mtdd меняется через MTProxyL, а не через API telemt")
}
