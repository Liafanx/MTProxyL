package mtproxylctl

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

// Живой вывод должен появляться ДО завершения команды — иначе смысла нет.
func TestProgressVisibleWhileRunning(t *testing.T) {
	script := t.TempDir() + "/slow.sh"
	body := "#!/bin/bash\n" +
		"echo '\033[0;34m[i]\033[0m Установка зависимостей...'\n" +
		"sleep 1\n" +
		"echo '[i] Скачивание PQ nginx...'\n" +
		"sleep 1\n" +
		"echo '[OK] готово'\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})
	r := NewRunner()

	if !r.Start("selfmask:apply", func(ctx context.Context) (string, error) {
		return c.run(ctx, "apply")
	}) {
		t.Fatal("не запустилось")
	}

	time.Sleep(1500 * time.Millisecond)
	mid := r.Status()
	if mid.Phase != PhaseRunning {
		t.Fatalf("ожидалось running, получено %s", mid.Phase)
	}
	if !strings.Contains(mid.Progress, "Установка зависимостей") {
		t.Fatalf("живого вывода нет: %q", mid.Progress)
	}
	if strings.Contains(mid.Progress, "\033[") {
		t.Fatalf("ANSI-коды не срезаны: %q", mid.Progress)
	}
	if mid.ElapsedSeconds < 1 {
		t.Fatalf("время не считается: %d", mid.ElapsedSeconds)
	}
	t.Logf("на 1.5с: elapsed=%ds progress=%q", mid.ElapsedSeconds, strings.TrimSpace(mid.Progress))

	deadline := time.Now().Add(10 * time.Second)
	for r.Busy() && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	final := r.Status()
	if final.Phase != PhaseDone {
		t.Fatalf("ожидалось done, получено %s (%s)", final.Phase, final.Error)
	}
	if !strings.Contains(final.Progress, "готово") {
		t.Fatalf("финальный вывод неполон: %q", final.Progress)
	}
	t.Logf("итог: phase=%s elapsed=%ds", final.Phase, final.ElapsedSeconds)
}

// Упавшая команда должна отдавать и ошибку, и то, что успела напечатать.
func TestProgressKeptOnFailure(t *testing.T) {
	script := t.TempDir() + "/fail.sh"
	body := "#!/bin/bash\necho '[i] шаг 1'\necho '[X] Не удалось получить сертификат' >&2\nexit 1\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})
	r := NewRunner()
	r.Start("selfmask:apply", func(ctx context.Context) (string, error) { return c.run(ctx, "apply") })

	deadline := time.Now().Add(5 * time.Second)
	for r.Busy() && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	st := r.Status()
	if st.Phase != PhaseFailed {
		t.Fatalf("ожидалось failed, получено %s", st.Phase)
	}
	if !strings.Contains(st.Error, "сертификат") {
		t.Fatalf("сообщение об ошибке потеряно: %q", st.Error)
	}
	if !strings.Contains(st.Progress, "шаг 1") {
		t.Fatalf("вывод до падения потерян: %q", st.Progress)
	}
	t.Logf("ошибка: %s", st.Error)
}
