package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

func newWarpMux(t *testing.T, script string) (*http.ServeMux, *mtproxylctl.Runner) {
	t.Helper()
	cfg := config.MtproxylConfig{Enabled: true, ScriptPath: script}
	client := mtproxylctl.New(cfg)
	runner := mtproxylctl.NewRunner()
	s := New(&config.Config{Mtproxyl: cfg})
	mux := http.NewServeMux()
	s.registerWarpRoutes(mux, testJWTSecret, client, runner)
	return mux, runner
}

func TestWarpEnableForwardsExplicitConsents(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	record := filepath.Join(dir, "args")
	body := `#!/bin/sh
if [ "$*" = 'warp preflight upstream --json' ]; then
  echo '{"mode":"upstream","middle_proxy_enabled":true,"can_disable_middle_proxy":true,"owns_engine_config":true,"manual_engine_config":false,"default_upstreams":["direct"],"can_disable_default_upstreams":true}'
  exit 0
fi
printf '%s\n' "$@" > "` + record + `"
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	mux, runner := newWarpMux(t, script)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/warp/preflight?mode=upstream", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("preflight: %d %s", rec.Code, rec.Body.String())
	}
	var preflight struct {
		Data mtproxylctl.WarpPreflight `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &preflight); err != nil {
		t.Fatal(err)
	}
	if !preflight.Data.MiddleProxyEnabled || len(preflight.Data.DefaultUpstreams) != 1 {
		t.Fatalf("preflight: %+v", preflight.Data)
	}

	rec = httptest.NewRecorder()
	bodyJSON := `{"mode":"upstream","allow_disable_middle_proxy":true,"allow_disable_default_upstreams":true}`
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/warp/enable", bodyJSON))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body.String())
	}
	deadline := time.Now().Add(2 * time.Second)
	for runner.Busy() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	got, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	want := "warp\non\nupstream\n--allow-disable-me\n--allow-disable-default-upstreams\n"
	if string(got) != want {
		t.Fatalf("args: %q", got)
	}
}

func TestWarpEnableDoesNotInventConsent(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	record := filepath.Join(dir, "args")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > '"+record+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	mux, runner := newWarpMux(t, script)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/warp/enable", `{"mode":"socks"}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body.String())
	}
	deadline := time.Now().Add(time.Second)
	for runner.Busy() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	got, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(got), "--allow-disable") {
		t.Fatalf("implicit consent: %q", got)
	}
}
