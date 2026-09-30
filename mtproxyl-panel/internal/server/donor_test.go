package server

import (
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

func newDonorMux(t *testing.T, script string) (*http.ServeMux, *mtproxylctl.Runner) {
	t.Helper()
	cfg := config.MtproxylConfig{Enabled: true, ScriptPath: script}
	client := mtproxylctl.New(cfg)
	runner := mtproxylctl.NewRunner()
	s := New(&config.Config{Mtproxyl: cfg})
	mux := http.NewServeMux()
	s.registerDonorRoutes(mux, testJWTSecret, client, runner)
	return mux, runner
}

// Скрипт записывает аргументы и stdin: пароль должен прийти только во втором.
func recordingScript(t *testing.T) (script, args, stdin string) {
	t.Helper()
	dir := t.TempDir()
	script = filepath.Join(dir, "cli")
	args = filepath.Join(dir, "args")
	stdin = filepath.Join(dir, "stdin")
	body := `#!/bin/sh
printf '%s\n' "$@" > "` + args + `"
cat > "` + stdin + `"
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	return script, args, stdin
}

func waitRunner(runner *mtproxylctl.Runner) {
	deadline := time.Now().Add(2 * time.Second)
	for runner.Busy() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
}

const testHostKey = "SHA256:ThD052sQ98w9W5vmUHU1NTqo2w1RnVqFwmY1d2rahFc"

func TestDonorSetupPasswordOnlyOnStdin(t *testing.T) {
	script, argsFile, stdinFile := recordingScript(t)
	mux, runner := newDonorMux(t, script)
	body := `{"host":"31.76.78.135","password":"s3cr3t pass","host_key":"` + testHostKey + `","mtu":1360,"allow_disable_default_upstreams":true}`
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/donor/setup", body))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("setup: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	want := "donor\nsetup\n31.76.78.135\n--ssh-port\n22\n--user\nroot\n--mtu\n1360\n--host-key\n" + testHostKey +
		"\n--password-stdin\n--yes\n--allow-disable-default-upstreams\n"
	if string(args) != want {
		t.Fatalf("args: %q", args)
	}
	if strings.Contains(string(args), "s3cr3t") {
		t.Fatal("пароль попал в аргументы")
	}
	stdin, _ := os.ReadFile(stdinFile)
	if string(stdin) != "s3cr3t pass\n" {
		t.Fatalf("stdin: %q", stdin)
	}
}

func TestDonorSetupRejectsBadInput(t *testing.T) {
	script, argsFile, _ := recordingScript(t)
	mux, _ := newDonorMux(t, script)
	cases := []string{
		`{"host":"1.2.3.4; id","host_key":"` + testHostKey + `"}`,
		`{"host":"127.0.0.1","host_key":"` + testHostKey + `"}`,
		`{"host":"31.76.78.135"}`,
		`{"host":"31.76.78.135","host_key":"` + testHostKey + `","user":"root --yes"}`,
		`{"host":"31.76.78.135","host_key":"` + testHostKey + `","password":"a\nb"}`,
		`{"host":"31.76.78.135","host_key":"` + testHostKey + `","awg_port":70000}`,
		`{"host":"31.76.78.135","host_key":"` + testHostKey + `","mtu":1500}`,
	}
	for _, body := range cases {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/donor/setup", body))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s", body, rec.Code, rec.Body.String())
		}
	}
	if _, err := os.Stat(argsFile); err == nil {
		t.Fatal("скрипт вызван при неверном вводе")
	}
}

func TestDonorFinishAndRemove(t *testing.T) {
	script, argsFile, stdinFile := recordingScript(t)
	mux, runner := newDonorMux(t, script)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/donor/finish", `{"key":"not-a-key"}`))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("bad key: %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/donor/finish",
		`{"key":"2ui1qJ7cxFn7rCW40mxNiwPstT3j+sPWOaImaI5HUWc="}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("finish: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	if got, _ := os.ReadFile(argsFile); string(got) != "donor\nfinish\n2ui1qJ7cxFn7rCW40mxNiwPstT3j+sPWOaImaI5HUWc=\n--yes\n" {
		t.Fatalf("finish args: %q", got)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/donor/remove", `{"remote":true,"password":"pw"}`))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("remove: %d %s", rec.Code, rec.Body.String())
	}
	waitRunner(runner)
	if got, _ := os.ReadFile(argsFile); string(got) != "donor\nremove\n--yes\n--remote\n--password-stdin\n" {
		t.Fatalf("remove args: %q", got)
	}
	if got, _ := os.ReadFile(stdinFile); string(got) != "pw\n" {
		t.Fatalf("remove stdin: %q", got)
	}
}

func TestDonorStatusParses(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	body := `#!/bin/sh
echo '{"configured":true,"stage":"ready","enabled":true,"setup_mode":"auto","host":"31.76.78.135","ssh_port":22,"ssh_user":"root","awg_port":41170,"net":"10.218.153.52","iface":"mtpdonor","remote_iface":"mtple5d3da","socks":"10.218.153.53:1080","awg_installed":true,"tunnel_up":true,"handshake_age":30,"rx_bytes":1,"tx_bytes":2,"egress_ip":"31.76.78.135","public_ip":"31.76.78.135","ipv6":false,"engine_mode":"manager","engine_routed":"manager","disabled_upstreams":"direct","default_upstreams":"","warp_enabled":false,"setup_at":1,"check":{"at":2,"result":"ok","egress_ip":"31.76.78.135","rtt_ms":null,"error":""},"manual_script":false}'
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	mux, _ := newDonorMux(t, script)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/donor/status", ""))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"socks":"10.218.153.53:1080"`) {
		t.Fatalf("status: %d %s", rec.Code, rec.Body.String())
	}
}
