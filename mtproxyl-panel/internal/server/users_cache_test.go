package server

import (
	"context"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// countingSecretList возвращает подставной "mtproxyl" скрипт: на каждый
// запуск дописывает байт в counter (реальное число процессов) и, после
// задержки, отдаёт пустой JSON-список секретов.
func countingSecretList(t *testing.T, delay time.Duration) (script, counter string) {
	t.Helper()
	dir := t.TempDir()
	counter = dir + "/calls"
	if err := os.WriteFile(counter, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	script = dir + "/mtproxyl.sh"
	body := fmt.Sprintf("#!/bin/bash\nprintf x >> '%s'\nsleep %f\necho '[]'\n", counter, delay.Seconds())
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return script, counter
}

// resetUsersCache возвращает пакетное состояние кэша к нулю между тестами:
// он глобальный, и без сброса результат одного теста утекал бы в следующий.
func resetUsersCache() {
	usersCache.mu.Lock()
	usersCache.at = time.Time{}
	usersCache.val, usersCache.err = nil, nil
	usersCache.inFlight = nil
	usersCache.mu.Unlock()
}

func TestCachedUsersCoalescesConcurrentCalls(t *testing.T) {
	resetUsersCache()

	script, counter := countingSecretList(t, 200*time.Millisecond)
	c := mtproxylctl.New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			_, err := cachedUsers(context.Background(), c)
			errs[i] = err
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("вызов %d: %v", i, err)
		}
	}

	calls, err := os.ReadFile(counter)
	if err != nil {
		t.Fatal(err)
	}
	// 20 конкурентных вызовов должны свернуться в один реальный процесс —
	// без дедупликации здесь было бы до 20 одновременных "mtproxyl.sh".
	if got := len(calls); got != 1 {
		t.Fatalf("реальных вызовов CLI: %d, ожидался 1 (20 конкурентных запросов не свернулись)", got)
	}
}

func TestCachedUsersServesFromCacheWithinTTL(t *testing.T) {
	resetUsersCache()

	script, counter := countingSecretList(t, 0)
	c := mtproxylctl.New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})

	if _, err := cachedUsers(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if _, err := cachedUsers(context.Background(), c); err != nil {
		t.Fatal(err)
	}

	calls, _ := os.ReadFile(counter)
	if got := len(calls); got != 1 {
		t.Fatalf("второй вызов в пределах TTL не должен был запускать CLI заново: вызовов %d", got)
	}
}

func TestInvalidateUsersCacheForcesRefetch(t *testing.T) {
	resetUsersCache()

	script, counter := countingSecretList(t, 0)
	c := mtproxylctl.New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})

	if _, err := cachedUsers(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	invalidateUsersCache()
	if _, err := cachedUsers(context.Background(), c); err != nil {
		t.Fatal(err)
	}

	calls, _ := os.ReadFile(counter)
	if got := len(calls); got != 2 {
		t.Fatalf("после invalidate ожидался повторный вызов CLI: вызовов %d", got)
	}
}
