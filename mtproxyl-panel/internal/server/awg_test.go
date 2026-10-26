package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

func newAwgMux(t *testing.T, script string) (*http.ServeMux, *mtproxylctl.Runner) {
	t.Helper()
	cfg := config.MtproxylConfig{Enabled: true, ScriptPath: script}
	client := mtproxylctl.New(cfg)
	runner := mtproxylctl.NewRunner()
	s := New(&config.Config{Mtproxyl: cfg})
	mux := http.NewServeMux()
	s.registerAwgRoutes(mux, testJWTSecret, client, runner)
	return mux, runner
}

// Тело конфига с ключом идёт только через stdin.
func TestAwgImportBodyOnStdin(t *testing.T) {
	script, argsFile, stdinFile := recordingScript(t)
	mux, _ := newAwgMux(t, script)
	conf := "[Interface]\nPrivateKey = SH3OIYp3CI4y87GeQiH6RpoZno//jwFfCy4dZAm3qnQ=\n"
	body, _ := json.Marshal(map[string]string{"name": "home-1", "body": conf})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/import", string(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("import: %d %s", rec.Code, rec.Body.String())
	}
	args, _ := os.ReadFile(argsFile)
	if string(args) != "awg\nimport\n-\n--name\nhome-1\n" {
		t.Fatalf("args: %q", args)
	}
	stdin, _ := os.ReadFile(stdinFile)
	if string(stdin) != conf {
		t.Fatalf("stdin: %q", stdin)
	}
}

func TestAwgImportPathAndEnable(t *testing.T) {
	script, argsFile, _ := recordingScript(t)
	mux, runner := newAwgMux(t, script)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/import",
		`{"name":"vpn","path":"/opt/mtproxyl/My VPN.conf"}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("import path: %d %s", rec.Code, rec.Body.String())
	}
	args, _ := os.ReadFile(argsFile)
	if string(args) != "awg\nimport\n/opt/mtproxyl/My VPN.conf\n--name\nvpn\n" {
		t.Fatalf("args: %q", args)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/enable",
		`{"name":"vpn","mtu":1280,"allow_disable_me":true}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	args, _ = os.ReadFile(argsFile)
	if string(args) != "awg\non\nvpn\n--yes\n--mtu\n1280\n--allow-disable-me\n" {
		t.Fatalf("args: %q", args)
	}
}

func TestAwgEnableSeveralAndOrder(t *testing.T) {
	script, argsFile, _ := recordingScript(t)
	mux, runner := newAwgMux(t, script)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/enable", `{"names":["main","spare-1"]}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	if args, _ := os.ReadFile(argsFile); string(args) != "awg\non\nmain\nspare-1\n--yes\n" {
		t.Fatalf("args: %q", args)
	}
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/order", `{"names":["spare-1","main"]}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("order: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	if args, _ := os.ReadFile(argsFile); string(args) != "awg\norder\nspare-1\nmain\n" {
		t.Fatalf("args: %q", args)
	}
}

func TestAwgRejectsBadInput(t *testing.T) {
	script, argsFile, _ := recordingScript(t)
	mux, _ := newAwgMux(t, script)
	cases := []struct{ path, body string }{
		{"/api/awg/import", `{"name":"a b","body":"x"}`},
		{"/api/awg/import", `{"name":"--yes","body":"x"}`},
		{"/api/awg/import", `{"name":"ok","path":"/etc/shadow"}`},
		{"/api/awg/import", `{"name":"ok","path":"/opt/../etc/x.conf"}`},
		{"/api/awg/import", `{"name":"ok","path":"relative.conf"}`},
		{"/api/awg/import", `{"name":"ok"}`},
		{"/api/awg/import", `{"name":"ok","body":"` + strings.Repeat("a", mtproxylctl.AwgConfigMax+1) + `"}`},
		{"/api/awg/enable", `{"name":"vpn --mtu 1"}`},
		{"/api/awg/enable", `{"name":"vpn","mtu":9000}`},
		{"/api/awg/enable", `{"names":["a","a"]}`},
		{"/api/awg/enable", `{"names":["a","b","c","d","e","f","g","h","i"]}`},
		{"/api/awg/order", `{"names":[]}`},
		{"/api/awg/order", `{"names":["ok","--yes"]}`},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, c.path, c.body))
		if rec.Code == http.StatusOK || rec.Code == http.StatusAccepted {
			t.Fatalf("%s %s: %d", c.path, c.body[:min(len(c.body), 60)], rec.Code)
		}
	}
	if _, err := os.Stat(argsFile); err == nil {
		t.Fatal("скрипт вызван при неверном вводе")
	}
}

// Чужой выход выключается только по явному replace.
func TestAwgEnableReplace(t *testing.T) {
	script, argsFile, _ := recordingScript(t)
	mux, runner := newAwgMux(t, script)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/enable", `{"names":["main"],"replace":true}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	if args, _ := os.ReadFile(argsFile); string(args) != "awg\non\nmain\n--yes\n--replace\n" {
		t.Fatalf("args: %q", args)
	}
}

func TestAwgTimersAndEgress(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	script := filepath.Join(dir, "cli")
	body := `#!/bin/sh
echo "$*" >> "` + log + `"
case "$1" in
  egress) echo '{"via":"awg","label":"x","name":"main","egress_ip":"203.0.113.7","ok":false,"error":"","fail_since":5,"awg":{"order":["main","spare"],"failover_after":60,"failback_every":120,"last_switch":{"at":0,"from":"","to":"","reason":""},"primary_check":{"at":0,"result":""}}}' ;;
  awg) [ "$2" = status ] && echo '{"enabled":true,"active":"main","failover_after":60,"failback_every":300,"configs":[]}' ;;
esac
exit 0
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	mux, _ := newAwgMux(t, script)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/timers", `{"failover_after":60,"failback_every":300}`))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"failback_every":300`) {
		t.Fatalf("timers: %d %s", rec.Code, rec.Body.String())
	}
	for _, bad := range []string{`{"failover_after":30,"failback_every":300}`, `{"failover_after":60,"failback_every":100000}`} {
		rec = httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/awg/timers", bad))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("timers %s: %d", bad, rec.Code)
		}
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/egress", ""))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"via":"awg"`) || !strings.Contains(rec.Body.String(), `"ok":false`) {
		t.Fatalf("egress: %d %s", rec.Code, rec.Body.String())
	}
	calls, _ := os.ReadFile(log)
	if !strings.Contains(string(calls), "awg timers 60 300\n") || !strings.Contains(string(calls), "egress --json\n") {
		t.Fatalf("calls: %q", calls)
	}
}
