package mtproxylctl

import (
	"bytes"
	"context"
	"io"
	"sync"
)

// Progress collects a running command's output so the UI can show it before the
// command finishes.
//
// Selfmask provisioning, mode switches and restores take minutes. Without this
// the panel shows a spinner and nothing else, and there is no way to tell a
// slow step from a stuck one — which is exactly how a long apt-get looks.
type Progress struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

// maxProgressBytes caps what is retained. Output is only ever a few kilobytes
// of log lines, but a runaway command must not grow the buffer without bound.
const maxProgressBytes = 64 * 1024

func (p *Progress) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.buf.Write(b)
	// Keep the tail: the newest lines are the ones that say where it is now.
	if p.buf.Len() > maxProgressBytes {
		trimmed := p.buf.Bytes()[p.buf.Len()-maxProgressBytes:]
		keep := make([]byte, len(trimmed))
		copy(keep, trimmed)
		p.buf.Reset()
		p.buf.Write(keep)
	}
	return len(b), nil
}

// String returns the output collected so far, without terminal colors.
func (p *Progress) String() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return stripANSI(p.buf.String())
}

type progressKey struct{}

// WithProgress attaches a sink that run() mirrors command output into.
//
// Passing it through the context rather than every method signature keeps the
// command wrappers unchanged: a call that wants live output opts in, the rest
// behave exactly as before.
func WithProgress(ctx context.Context, w io.Writer) context.Context {
	return context.WithValue(ctx, progressKey{}, w)
}

func progressFrom(ctx context.Context) io.Writer {
	w, _ := ctx.Value(progressKey{}).(io.Writer)
	return w
}
