package mtddshim

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// Снимок в той форме, что печатает `mtproxyl target-api snapshot`
// (lib/mtdd.sh, cmd_snapshot; тот же набор проверяет tests/mtdd_adapter.sh).
const snapJSON = `{"engine":"mtdd","version":"0.1.0","full_api":true,"taken_at":1,
"users":[{"username":"alice","enabled":true,"current_connections":2,"active_unique_ips":1,"total_octets":300,
  "links":{"tls":["tg://proxy?server=203.0.113.10&port=443&secret=ee00112233445566778899aabbccddeeff6578616d706c652e6f7267"],"classic":[],"secure":[]},
  "data_quota_bytes":1000,"quota_used_bytes":10,"active_unique_ips_list":["198.51.100.7"]},
 {"username":"bob","enabled":false,"current_connections":0,"active_unique_ips":0,"total_octets":0}],
"summary":{"uptime_seconds":42,"connections_total":10,"connections_bad_total":3,"connections_bad_by_class":[],
  "handshake_timeouts_total":2,"handshake_failures_by_class":[],"configured_users":2},
"system_info":{"version":"0.1.0","config_path":"","config_hash":""},
"health":{"status":"ok","read_only":false},
"dcs":{"middle_proxy_enabled":true,"dcs":[{"dc":2,"rtt_ms":41,"alive_writers":2,"required_writers":2,"available_pct":100,"coverage_pct":100}]},
"active_ips":[{"username":"alice","active_ips":["198.51.100.7"]}],
"quota":{"users":[{"username":"alice","data_quota_bytes":1000,"used_bytes":10,"last_reset_epoch_secs":null}]},
"connections":{"current_connections":2,"active_users":1}}`

type fakeSource struct {
	mu        sync.Mutex
	kind      string
	modeErr   error
	snapErr   error
	modeCalls int
	snapCalls int
	resets    []string
}

func (f *fakeSource) GetMode(context.Context) (*mtproxylctl.ModeStatus, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.modeCalls++
	if f.modeErr != nil {
		return nil, f.modeErr
	}
	return &mtproxylctl.ModeStatus{Mode: mtproxylctl.ModeReanimator, EngineKind: f.kind}, nil
}

func (f *fakeSource) TargetSnapshot(context.Context) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.snapCalls++
	if f.snapErr != nil {
		return nil, f.snapErr
	}
	return []byte(snapJSON), nil
}

func (f *fakeSource) ResetQuota(_ context.Context, label string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resets = append(f.resets, label)
	return "ok", nil
}

// Настоящий telemt за спиной: на mtdd до него не должен дойти ни один запрос.
func upstream(t *testing.T, hits *int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ok":true,"data":{"from":"telemt"}}`)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func do(t *testing.T, c *http.Client, method, url string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader("{}"))
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	var env map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		t.Fatalf("%s %s: decode: %v", method, url, err)
	}
	return resp.StatusCode, env
}

func TestTelemtTargetPassesThrough(t *testing.T) {
	hits := 0
	srv := upstream(t, &hits)
	src := &fakeSource{kind: "telemt"}
	c := &http.Client{Transport: New(src).Wrap(nil)}
	_, env := do(t, c, http.MethodGet, srv.URL+"/v1/users")
	if hits != 1 || env["data"].(map[string]any)["from"] != "telemt" {
		t.Fatalf("telemt target must reach telemt: hits=%d env=%v", hits, env)
	}
	if src.snapCalls != 0 {
		t.Fatalf("snapshot taken for a telemt target")
	}
}

func TestMtddServesFromOneSnapshot(t *testing.T) {
	hits := 0
	srv := upstream(t, &hits)
	src := &fakeSource{kind: "mtdd"}
	c := &http.Client{Transport: New(src).Wrap(nil)}

	st, env := do(t, c, http.MethodGet, srv.URL+"/v1/users")
	users, _ := env["data"].([]any)
	if st != 200 || env["ok"] != true || len(users) != 2 {
		t.Fatalf("/v1/users: %d %v", st, env)
	}
	if u := users[0].(map[string]any); u["username"] != "alice" || u["total_octets"].(float64) != 300 {
		t.Fatalf("user shape: %v", u)
	}
	for path, key := range map[string]string{
		"/v1/stats/summary":               "connections_total",
		"/v1/system/info":                 "version",
		"/v1/health":                      "status",
		"/v1/stats/dcs":                   "dcs",
		"/v1/stats/users/quota":           "users",
		"/v1/runtime/connections/summary": "enabled",
	} {
		st, env := do(t, c, http.MethodGet, srv.URL+path)
		data, _ := env["data"].(map[string]any)
		if st != 200 || env["ok"] != true || data[key] == nil {
			t.Fatalf("%s: %d %v", path, st, env)
		}
	}
	st, env = do(t, c, http.MethodGet, srv.URL+"/v1/stats/users/active-ips")
	if ips, _ := env["data"].([]any); st != 200 || len(ips) != 1 {
		t.Fatalf("active-ips: %d %v", st, env)
	}
	st, env = do(t, c, http.MethodGet, srv.URL+"/v1/users/bob")
	if st != 200 || env["data"].(map[string]any)["username"] != "bob" {
		t.Fatalf("/v1/users/bob: %d %v", st, env)
	}
	if st, _ = do(t, c, http.MethodGet, srv.URL+"/v1/users/nobody"); st != 404 {
		t.Fatalf("unknown user: %d", st)
	}
	if hits != 0 {
		t.Fatalf("mtdd target reached telemt %d times", hits)
	}
	if src.snapCalls != 1 {
		t.Fatalf("snapshot must be shared between requests, calls=%d", src.snapCalls)
	}
}

func TestMtddUnsupportedAndGatedPaths(t *testing.T) {
	hits := 0
	srv := upstream(t, &hits)
	c := &http.Client{Transport: New(&fakeSource{kind: "mtdd"}).Wrap(nil)}

	st, env := do(t, c, http.MethodGet, srv.URL+"/v1/runtime/tls-fingerprints?limit=500")
	if st != 200 || env["data"].(map[string]any)["enabled"] != false {
		t.Fatalf("fingerprints must be a closed gate: %d %v", st, env)
	}
	st, env = do(t, c, http.MethodGet, srv.URL+"/v1/security/posture")
	if st != http.StatusNotImplemented || env["ok"] != false ||
		env["error"].(map[string]any)["code"] != "not_supported_by_mtdd" {
		t.Fatalf("unknown path: %d %v", st, env)
	}
	for _, m := range []string{http.MethodPost, http.MethodPatch, http.MethodDelete} {
		if st, _ := do(t, c, m, srv.URL+"/v1/users/alice"); st != http.StatusNotImplemented {
			t.Fatalf("%s must be refused: %d", m, st)
		}
	}
	if hits != 0 {
		t.Fatalf("reached telemt %d times", hits)
	}
}

func TestMtddResetQuotaGoesThroughCLI(t *testing.T) {
	srv := upstream(t, new(int))
	src := &fakeSource{kind: "mtdd"}
	shim := New(src)
	c := &http.Client{Transport: shim.Wrap(nil)}
	do(t, c, http.MethodGet, srv.URL+"/v1/users")
	st, env := do(t, c, http.MethodPost, srv.URL+"/v1/users/alice/reset-quota")
	if st != 200 || env["ok"] != true || len(src.resets) != 1 || src.resets[0] != "alice" {
		t.Fatalf("reset-quota: %d %v resets=%v", st, env, src.resets)
	}
	do(t, c, http.MethodGet, srv.URL+"/v1/users")
	if src.snapCalls != 2 {
		t.Fatalf("reset must drop the cached snapshot, calls=%d", src.snapCalls)
	}
}

func TestSnapshotErrorIsAnEnvelope(t *testing.T) {
	srv := upstream(t, new(int))
	c := &http.Client{Transport: New(&fakeSource{kind: "mtdd", snapErr: errors.New("boom")}).Wrap(nil)}
	st, env := do(t, c, http.MethodGet, srv.URL+"/v1/users")
	if st != http.StatusBadGateway || env["ok"] != false ||
		!strings.Contains(env["error"].(map[string]any)["message"].(string), "boom") {
		t.Fatalf("snapshot failure: %d %v", st, env)
	}
}

func TestModeIsCachedAndErrorKeepsLastAnswer(t *testing.T) {
	src := &fakeSource{kind: "mtdd"}
	shim := New(src)
	now := time.Unix(1000, 0)
	shim.now = func() time.Time { return now }
	ctx := context.Background()
	// Два запроса подряд — один вызов CLI: второй ответ из кэша.
	first := shim.Active(ctx)
	second := shim.Active(ctx)
	if !first || !second || src.modeCalls != 1 {
		t.Fatalf("mode must be cached: calls=%d", src.modeCalls)
	}
	set := func(kind string, err error) {
		src.mu.Lock()
		src.kind, src.modeErr = kind, err
		src.mu.Unlock()
	}
	calls := func() int {
		src.mu.Lock()
		defer src.mu.Unlock()
		return src.modeCalls
	}

	// Устаревший ответ отдаётся сразу, режим перечитывается в фоне.
	now = now.Add(time.Minute)
	set("mtdd", errors.New("sudo: a password is required"))
	if !shim.Active(ctx) {
		t.Fatal("a stale answer must be served at once")
	}
	shim.refreshWG.Wait()
	if calls() != 2 || !shim.Active(ctx) {
		t.Fatalf("a CLI error must keep the last known engine: calls=%d", calls())
	}

	// Фон узнал о смене движка — следующий запрос видит новый.
	now = now.Add(time.Minute)
	set("telemt", nil)
	if !shim.Active(ctx) {
		t.Fatal("the stale answer is served while the refresh runs")
	}
	shim.refreshWG.Wait()
	if shim.Active(ctx) {
		t.Fatal("the background refresh must pick up the new engine")
	}

	// После Invalidate первый запрос ждёт свежего ответа.
	set("mtdd", nil)
	shim.Invalidate()
	if !shim.Active(ctx) {
		t.Fatal("after Invalidate the new engine must be read")
	}
}

func TestStaleModeDoesNotBlock(t *testing.T) {
	src := &blockingSource{fakeSource: fakeSource{kind: "telemt"}, gate: make(chan struct{})}
	shim := New(src)
	now := time.Unix(1000, 0)
	shim.now = func() time.Time { return now }
	close(src.gate) // первый ответ — сразу
	shim.Active(context.Background())
	src.gate = make(chan struct{})
	now = now.Add(time.Minute)
	done := make(chan bool, 1)
	go func() { done <- shim.Active(context.Background()) }()
	select {
	case v := <-done:
		if v {
			t.Fatal("stale answer must be telemt")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a stale cache must not make a request wait for the CLI")
	}
	close(src.gate)
	shim.refreshWG.Wait()
}

// blockingSource holds GetMode until gate is closed.
type blockingSource struct {
	fakeSource
	gate chan struct{}
}

func (b *blockingSource) GetMode(ctx context.Context) (*mtproxylctl.ModeStatus, error) {
	<-b.gate
	return b.fakeSource.GetMode(ctx)
}
