package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
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
