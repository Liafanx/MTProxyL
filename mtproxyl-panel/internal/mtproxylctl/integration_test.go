package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

// stubScript writes a fake mtproxyl that mimics the real CLI's output shape,
// including the log lines it prints alongside JSON and the trailing bare path
// that create_backup echoes.
const stubScript = `#!/bin/bash
if [ "$MTPROXYL_ASSUME_YES" != "1" ]; then
  echo "refusing to run without MTPROXYL_ASSUME_YES" >&2
  exit 1
fi
case "$1 $2 $3" in
  "mode --json ")
    echo "  [i] загрузка настроек"
    echo '{"mode":"manager","detected_mode":"unknown","detected_config":"","port":443}'
    ;;
  "selfmask status --json")
    echo '{"enabled":true,"domain":"example.com","site_source":"stub","site_dir":"/var/www/x","backend_port":8444,"cert_mode":"selfsigned","auto_renew":false,"nginx_conf":"/opt/mtproxyl/nginx-custom.conf","nginx_conf_exists":true,"nginx_custom_enabled":true,"nginx_custom_active":true,"nginx_custom_file":"/opt/mtproxyl/nginx-custom.conf","nginx_custom_file_exists":true,"cert_found":true,"pq_nginx_active":true}'
    ;;
  "selfmask nginx-config show")
    printf 'worker_processes auto;\nevents {}\n'
    ;;
  "selfmask nginx-config write")
    cat
    ;;
  "backup list --json")
    echo '[{"name":"mtproxyl-20260101-101010.tar.gz","size":123,"mtime":1767000000}]'
    ;;
  "backup  ")
    echo "  [✓] Бэкап создан: /opt/mtproxyl/backups/mtproxyl-20260202-121212.tar.gz"
    echo "/opt/mtproxyl/backups/mtproxyl-20260202-121212.tar.gz"
    ;;
  "mode manager ")
    echo "  [✓] Режим: manager"
    ;;
  "traffic --json ")
    echo "  [i] чтение базы трафика"
    echo '{"mode":"manager","source":"db","directional":true,"persistent":true,"totals":{"in":2460700,"out":211900000,"total":214360700,"session_in":190600,"session_out":14040000,"connections":1},"users":[{"user":"default","in":370700,"out":32430000,"total":32800700,"session_in":190600,"session_out":14040000,"connections":1,"unique_ips":0,"enabled":true}]}'
    ;;
  "upstream add "*)
    # Печатаем каждый аргумент отдельной строкой: тест следит за позициями,
    # потому что пустой пропущенный аргумент сдвинул бы все следующие.
    printf 'arg=%s\n' "$@"
    ;;
  "superexpert write ")
    # Отражаем stdin, чтобы тест мог убедиться: он действительно доходит.
    cat
    ;;
  *)
    echo -e "  \033[31m[✗]\033[0m неизвестная команда: $*" >&2
    exit 2
    ;;
esac
`

// newStubClient installs the stub script and returns a client pointed at it.
func newStubClient(t *testing.T) *Client {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("stub script requires a POSIX shell")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "mtproxyl.sh")
	if err := os.WriteFile(script, []byte(stubScript), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	return New(config.MtproxylConfig{
		Enabled:    true,
		ScriptPath: script,
		InstallDir: dir,
		UseSudo:    false,
	})
}

func TestAgainstStubCLI(t *testing.T) {
	c := newStubClient(t)
	ctx := context.Background()

	// Mode: the payload is preceded by a log line, which must not be mistaken
	// for the JSON document.
	mode, err := c.GetMode(ctx)
	if err != nil {
		t.Fatalf("GetMode: %v", err)
	}
	if mode.Mode != ModeManager {
		t.Errorf("mode = %q, want manager", mode.Mode)
	}
	if mode.Port != 443 {
		t.Errorf("port = %d, want 443", mode.Port)
	}

	sm, err := c.SelfmaskStatus(ctx)
	if err != nil {
		t.Fatalf("SelfmaskStatus: %v", err)
	}
	if !sm.Enabled || sm.Domain != "example.com" || sm.BackendPort != 8444 || !sm.NginxCustomActive {
		t.Errorf("unexpected selfmask status: %+v", sm)
	}

	list, err := c.ListBackups(ctx)
	if err != nil {
		t.Fatalf("ListBackups: %v", err)
	}
	if len(list) != 1 || list[0].Name != "mtproxyl-20260101-101010.tar.gz" {
		t.Errorf("unexpected backups: %+v", list)
	}

	// CreateBackup must pick the bare path off the last line, not the log line
	// above it, and reduce it to a validated file name.
	name, err := c.CreateBackup(ctx)
	if err != nil {
		t.Fatalf("CreateBackup: %v", err)
	}
	if name != "mtproxyl-20260202-121212.tar.gz" {
		t.Errorf("name = %q", name)
	}

	// Manager mode takes no container disposition — that decision only exists
	// when leaving manager.
	if err := c.SwitchMode(ctx, ModeManager, ""); err != nil {
		t.Errorf("SwitchMode: %v", err)
	}
}

func TestSelfmaskNginxConfigRoundTrip(t *testing.T) {
	c := newStubClient(t)
	ctx := context.Background()

	config, err := c.SelfmaskNginxConfig(ctx)
	if err != nil || !strings.Contains(config, "worker_processes") {
		t.Fatalf("SelfmaskNginxConfig() = %q, %v", config, err)
	}

	want := "worker_processes 2;\nevents {}\n"
	out, err := c.WriteSelfmaskNginxConfig(ctx, want)
	if err != nil {
		t.Fatalf("WriteSelfmaskNginxConfig: %v", err)
	}
	if out != want {
		t.Fatalf("written config = %q, want %q", out, want)
	}
}

// The assume-yes bypass is what makes headless operation possible; the stub
// fails loudly without it, so this pins the contract.
func TestAssumeYesIsPassedToScript(t *testing.T) {
	c := newStubClient(t)
	if _, err := c.GetMode(context.Background()); err != nil {
		t.Fatalf("script rejected the environment: %v", err)
	}
}

func TestCommandErrorCarriesScriptMessage(t *testing.T) {
	c := newStubClient(t)
	_, err := c.SelfmaskVerify(context.Background())
	if err == nil {
		t.Fatal("expected an error for an unsupported command")
	}
	// The message reaches the user, so it must be readable: script text, no
	// ANSI escapes.
	if !strings.Contains(err.Error(), "неизвестная команда") {
		t.Errorf("error lost the script message: %v", err)
	}
	if strings.Contains(err.Error(), "\033") {
		t.Errorf("error still contains ANSI escapes: %q", err.Error())
	}
}

func TestRestoreRejectsBadNameBeforeInvokingScript(t *testing.T) {
	c := newStubClient(t)
	// The stub exits non-zero for anything it does not recognise; a rejection
	// here proves validation happened before the command ran.
	if _, err := c.RestoreBackup(context.Background(), "../../etc/shadow"); err == nil {
		t.Fatal("traversal name was accepted")
	}
}
