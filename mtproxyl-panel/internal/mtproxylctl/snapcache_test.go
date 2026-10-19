package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSnapCacheServesCachedAndRefreshesInBackground(t *testing.T) {
	var calls atomic.Int32
	c := &SnapCache[int32]{
		Load:  func(context.Context) (int32, error) { return calls.Add(1), nil },
		Fresh: 50 * time.Millisecond,
	}
	ctx := context.Background()
	if v, _ := c.Get(ctx); v != 1 {
		t.Fatalf("first Get = %d, want 1", v)
	}
	if v, _ := c.Get(ctx); v != 1 || calls.Load() != 1 {
		t.Fatalf("fresh Get = %d (calls %d), want cached 1", v, calls.Load())
	}
	time.Sleep(60 * time.Millisecond)
	// Устарело по времени: отдаём старое сразу, обновляем в фоне.
	if v, _ := c.Get(ctx); v != 1 {
		t.Fatalf("stale Get = %d, want 1 served immediately", v)
	}
	deadline := time.Now().Add(time.Second)
	for calls.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(10 * time.Millisecond)
	if v, _ := c.Get(ctx); v != 2 {
		t.Fatalf("after background refresh Get = %d, want 2", v)
	}
}

func TestSnapCacheWaitsWhenWatchedFileChanges(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "secrets.conf")
	if err := os.WriteFile(f, []byte("a"), 0o600); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	c := &SnapCache[int32]{
		Load:  func(context.Context) (int32, error) { return calls.Add(1), nil },
		Watch: []string{f},
		Fresh: time.Hour,
	}
	ctx := context.Background()
	c.Get(ctx)
	// Правка файла: следующий Get обязан вернуть свежее, а не кэш.
	if err := os.WriteFile(f, []byte("bb"), 0o600); err != nil {
		t.Fatal(err)
	}
	if v, _ := c.Get(ctx); v != 2 {
		t.Fatalf("Get after change = %d, want 2", v)
	}
}

func TestSnapCacheInvalidateIgnoresLoadStartedBefore(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int32
	c := &SnapCache[int32]{
		Load: func(context.Context) (int32, error) {
			n := calls.Add(1)
			if n == 1 {
				<-release
			}
			return n, nil
		},
	}
	ctx := context.Background()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); c.Get(ctx) }()
	for calls.Load() < 1 {
		time.Sleep(time.Millisecond)
	}
	// Запись прошла, пока шла загрузка: её результат уже не годится.
	c.Invalidate()
	go func() { time.Sleep(20 * time.Millisecond); close(release) }()
	if v, _ := c.Get(ctx); v != 2 {
		t.Fatalf("Get after Invalidate = %d, want 2 (fresh load)", v)
	}
	wg.Wait()
}

func TestSnapCacheCoalescesConcurrentCalls(t *testing.T) {
	var calls atomic.Int32
	c := &SnapCache[int32]{Load: func(context.Context) (int32, error) {
		time.Sleep(30 * time.Millisecond)
		return calls.Add(1), nil
	}}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); c.Get(context.Background()) }()
	}
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", calls.Load())
	}
}
