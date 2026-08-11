package mtproxylctl

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

// newUpdateStub installs a fake CLI whose `update` output matches the real one.
func newUpdateStub(t *testing.T, body string) *Client {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("stub script requires a POSIX shell")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "mtproxyl.sh")
	if err := os.WriteFile(script, []byte("#!/bin/bash\n"+body), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	return New(config.MtproxylConfig{
		Enabled:    true,
		ScriptPath: script,
		InstallDir: dir,
	})
}

func TestCheckUpdateParsesVerdict(t *testing.T) {
	c := newUpdateStub(t, `echo '{"current":"1.4.6","latest":"1.4.7","update_available":true,`+
		`"branch":"main","release_url":"https://example/v1.4.7","error":""}'`)

	info, err := c.CheckUpdate(context.Background())
	if err != nil {
		t.Fatalf("CheckUpdate: %v", err)
	}
	if info.Current != "1.4.6" || info.Latest != "1.4.7" || !info.UpdateAvailable {
		t.Errorf("неожиданный результат: %+v", info)
	}
	if info.Branch != "main" || info.ReleaseURL != "https://example/v1.4.7" {
		t.Errorf("неожиданный результат: %+v", info)
	}
}

// Недоступный github — не сбой команды: установленная версия всё равно известна
// и её надо показать, а о неудаче сказать полем error.
func TestCheckUpdateKeepsCurrentOnLookupFailure(t *testing.T) {
	c := newUpdateStub(t, `echo '{"current":"1.4.6","latest":"","update_available":false,`+
		`"branch":"main","release_url":"","error":"не удалось получить номер версии с github.com"}'`)

	info, err := c.CheckUpdate(context.Background())
	if err != nil {
		t.Fatalf("CheckUpdate: %v", err)
	}
	if info.Current != "1.4.6" || info.UpdateAvailable {
		t.Errorf("неожиданный результат: %+v", info)
	}
	if info.Error == "" {
		t.Error("поле error должно быть заполнено")
	}
}

// Правила sudo перечисляют подкоманды поимённо, поэтому у панели, обновлённой
// на месте, новой команды в списке нет — отказ должен объяснять, что делать.
func TestSudoDenialExplainsHowToFix(t *testing.T) {
	c := newUpdateStub(t, `echo "sudo: a password is required" >&2; exit 1`)

	_, err := c.CheckUpdate(context.Background())
	if err == nil {
		t.Fatal("ожидалась ошибка")
	}
	if !strings.Contains(err.Error(), "mtproxyl panel install") {
		t.Errorf("в ошибке нет подсказки про права: %s", err)
	}
}

// Панель может оказаться новее скрипта: тот напечатает свою справку вместо
// JSON, и об этом надо сказать понятно.
func TestCheckUpdateReportsOldCLI(t *testing.T) {
	c := newUpdateStub(t, `echo "  [x] Неизвестная команда: $*" >&2; exit 1`)

	if _, err := c.CheckUpdate(context.Background()); !errors.Is(err, ErrUpdateUnsupported) {
		t.Errorf("ошибка = %v, ожидалась ErrUpdateUnsupported", err)
	}
}

// Проверка ходит отдельной командой: флаг старые версии проглотили бы и
// запустили настоящее обновление вместо ответа о нём.
func TestCheckUpdateUsesOwnSubcommand(t *testing.T) {
	c := newUpdateStub(t, `[ "$1" = "update-check" ] || { echo "got: $*" >&2; exit 1; }
echo '{"current":"1.4.7","latest":"1.4.7","update_available":false}'`)

	if _, err := c.CheckUpdate(context.Background()); err != nil {
		t.Errorf("CheckUpdate: %v", err)
	}
}

func TestApplyUpdatePassesNoRestart(t *testing.T) {
	c := newUpdateStub(t, `printf 'args=%s\n' "$*"`)

	out, err := c.ApplyUpdate(context.Background())
	if err != nil {
		t.Fatalf("ApplyUpdate: %v", err)
	}
	if !strings.Contains(out, "args=update --no-restart") {
		t.Errorf("аргументы команды: %q", out)
	}
}
