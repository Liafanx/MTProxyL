package history

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

type fakeTelemt struct {
	srv       *httptest.Server
	total     atomic.Uint64
	bad       atomic.Uint64
	uptime    atomic.Int64
	fail      atomic.Bool
	gated     atomic.Bool
	current   atomic.Uint64
	octets    atomic.Uint64
	activeIPs atomic.Int64
}

func newFakeTelemt(t *testing.T) *fakeTelemt {
	f := &fakeTelemt{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if f.fail.Load() {
			w.WriteHeader(http.StatusBadGateway)
			w.Write([]byte(`{"ok":false,"error":{"code":"down","message":"restarting"}}`))
			return
		}
		var data any
		switch r.URL.Path {
		case "/v1/stats/summary":
			data = map[string]any{
				"uptime_seconds": f.uptime.Load(), "connections_total": f.total.Load(),
				"connections_bad_total": f.bad.Load(), "handshake_timeouts_total": 1,
				"configured_users": 3,
			}
		case "/v1/runtime/connections/summary":
			if f.gated.Load() {
				data = map[string]any{"enabled": false, "reason": "off"}
			} else {
				data = map[string]any{"enabled": true, "data": map[string]any{"totals": map[string]any{
					"current_connections": f.current.Load(), "active_users": 2,
				}}}
			}
		case "/v1/users":
			data = []map[string]any{
				{"username": "a", "total_octets": f.octets.Load(), "active_unique_ips": f.activeIPs.Load()},
				{"username": "b", "total_octets": 10, "active_unique_ips": 1},
			}
		default:
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"ok":false,"error":{"code":"not_found","message":""}}`))
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": data})
	}))
	t.Cleanup(f.srv.Close)
	return f
}

type httpFetcher struct{ base string }

func (h httpFetcher) GetJSON(ctx context.Context, path string, out any) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.base+path, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var env struct {
		OK   bool            `json:"ok"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return err
	}
	if !env.OK {
		return errors.New("api error")
	}
	return json.Unmarshal(env.Data, out)
}

func newTestRecorder(t *testing.T, f *fakeTelemt, start time.Time) (*Recorder, *time.Time) {
	clock := start
	rec := NewRecorder(httpFetcher{base: f.srv.URL})
	rec.now = func() time.Time { return clock }
	return rec, &clock
}

func TestRecorderStats(t *testing.T) {
	f := newFakeTelemt(t)
	f.total.Store(100)
	f.bad.Store(4)
	f.uptime.Store(1000)
	f.current.Store(7)
	start := time.Unix(1_700_000_000, 0)
	rec, clock := newTestRecorder(t, f, start)
	ctx := context.Background()

	rec.PollStats(ctx)
	*clock = start.Add(5 * time.Second)
	f.total.Store(130)
	f.bad.Store(6)
	f.uptime.Store(1005)
	f.current.Store(9)
	rec.PollStats(ctx)

	conn := rec.Ring().Range(MetricConnections, 0)
	if len(conn) != 2 || conn[0].V != 0 || conn[1].V != 30 {
		t.Fatalf("connections = %+v", conn)
	}
	ref := rec.Ring().Range(MetricRefusals, 0)
	if len(ref) != 2 || ref[1].V != 2 {
		t.Fatalf("refusals = %+v", ref)
	}
	cur := rec.Ring().Range(MetricCurrentConnections, 0)
	if len(cur) != 2 || cur[1].V != 9 {
		t.Fatalf("current_connections = %+v", cur)
	}
	if au := rec.Ring().Range(MetricActiveUsers, 0); len(au) != 2 || au[1].V != 2 {
		t.Fatalf("active_users = %+v", au)
	}
	if av, ok := rec.Ring().Newest(MetricAvailable); !ok || av.V != 1 {
		t.Fatalf("available = %+v", av)
	}

	*clock = start.Add(10 * time.Second)
	f.fail.Store(true)
	rec.PollStats(ctx)
	if av, _ := rec.Ring().Newest(MetricAvailable); av.V != 0 || av.TS != start.Unix()+10 {
		t.Fatalf("available after failure = %+v", av)
	}
	if conn := rec.Ring().Range(MetricConnections, 0); len(conn) != 2 {
		t.Fatalf("failed poll must not append connections: %+v", conn)
	}

	*clock = start.Add(15 * time.Second)
	f.fail.Store(false)
	f.gated.Store(true)
	f.total.Store(10)
	f.uptime.Store(3)
	rec.PollStats(ctx)
	conn = rec.Ring().Range(MetricConnections, 0)
	if conn[len(conn)-1].V != 40 {
		t.Fatalf("connections after engine restart = %v, want 40", conn[len(conn)-1].V)
	}
	if cur := rec.Ring().Range(MetricCurrentConnections, 0); len(cur) != 2 {
		t.Fatalf("gated connections summary must not append: %+v", cur)
	}
	if seen, enabled, reason := rec.EdgeGate(); !seen || enabled || reason != "off" {
		t.Fatalf("edge gate = %v %v %q", seen, enabled, reason)
	}
	s, err := rec.Series(MetricCurrentConnections, "15m", *clock)
	if err != nil || s.State != "disabled" || s.DisabledReason != "off" || len(s.Points) != 2 {
		t.Fatalf("gated series = %+v, %v", s, err)
	}
	if s, _ := rec.Series(MetricConnections, "15m", *clock); s.State == "disabled" {
		t.Fatalf("ungated metric must not report disabled")
	}
}

func TestRecorderUsers(t *testing.T) {
	f := newFakeTelemt(t)
	f.octets.Store(1000)
	f.activeIPs.Store(3)
	start := time.Unix(1_700_000_000, 0)
	rec, clock := newTestRecorder(t, f, start)
	ctx := context.Background()

	rec.PollUsers(ctx)
	*clock = start.Add(10 * time.Second)
	f.octets.Store(1500)
	f.activeIPs.Store(5)
	rec.PollUsers(ctx)

	ips := rec.Ring().Range(MetricActiveIPs, 0)
	if len(ips) != 2 || ips[0].V != 4 || ips[1].V != 6 {
		t.Fatalf("active_ips = %+v", ips)
	}
	tr := rec.Ring().Range(MetricTraffic, 0)
	if len(tr) != 2 || tr[0].V != 0 || tr[1].V != 500 {
		t.Fatalf("traffic = %+v", tr)
	}
}

func TestSeries(t *testing.T) {
	f := newFakeTelemt(t)
	start := time.Unix(1_700_000_000, 0)
	rec, clock := newTestRecorder(t, f, start)
	ctx := context.Background()

	if s, err := rec.Series(MetricConnections, "30m", start); err != nil || s.State != "empty" || s.Points == nil {
		t.Fatalf("empty series = %+v, %v", s, err)
	}
	for i := 0; i < 12; i++ {
		*clock = start.Add(time.Duration(i) * 5 * time.Second)
		rec.PollStats(ctx)
	}
	now := start.Add(55 * time.Second)
	s, err := rec.Series(MetricConnections, "15m", now)
	if err != nil {
		t.Fatal(err)
	}
	if s.State != "partial" || len(s.Points) != 12 || s.RetentionSecs != 7200 {
		t.Fatalf("young series = %+v", s)
	}
	if s.RequestedFrom != now.Unix()-900 || s.AvailableFrom == nil || *s.AvailableFrom != start.Unix() {
		t.Fatalf("bounds = %+v", s)
	}
	if s.SourceAvailable == nil || !*s.SourceAvailable {
		t.Fatalf("source_available = %v", s.SourceAvailable)
	}

	for i := 12; i < 200; i++ {
		*clock = start.Add(time.Duration(i) * 5 * time.Second)
		rec.PollStats(ctx)
	}
	now = start.Add(199 * 5 * time.Second)
	if s, _ = rec.Series(MetricConnections, "15m", now); s.State != "ready" {
		t.Fatalf("full window state = %s", s.State)
	}
	if s, _ = rec.Series(MetricConnections, "15m", now.Add(10*time.Minute)); s.State != "partial" {
		t.Fatalf("stale series state = %s", s.State)
	}
	if _, err := rec.Series("nope", "15m", now); err == nil {
		t.Fatal("unknown metric accepted")
	}
	if _, err := rec.Series(MetricConnections, "3d", now); err == nil {
		t.Fatal("unknown range accepted")
	}
	if got := Ranges(); len(got) != 4 || got[0] != "15m" || got[3] != "2h" {
		t.Fatalf("Ranges = %v", got)
	}
}

func TestRecorderRunStops(t *testing.T) {
	f := newFakeTelemt(t)
	rec := NewRecorder(httpFetcher{base: f.srv.URL})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { rec.Run(ctx); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not stop")
	}
	if _, ok := rec.Ring().Newest(MetricAvailable); !ok {
		t.Fatal("Run must poll once before waiting")
	}
}
