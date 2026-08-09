package mtproxylctl

import (
	"context"
	"sync"
	"time"
)

// Phase is the lifecycle state of a long-running MTProxyL operation.
type Phase string

const (
	PhaseIdle    Phase = "idle"
	PhaseRunning Phase = "running"
	PhaseDone    Phase = "done"
	PhaseFailed  Phase = "failed"
)

// OperationStatus is a snapshot of the currently tracked operation.
type OperationStatus struct {
	Phase Phase `json:"phase"`
	// Name identifies what is running, e.g. "mode:reanimator" or "selfmask:setup".
	Name      string    `json:"name,omitempty"`
	Output    string    `json:"output,omitempty"`
	Error     string    `json:"error,omitempty"`
	StartedAt time.Time `json:"started_at,omitempty"`
	EndedAt   time.Time `json:"ended_at,omitempty"`
	// Progress is what the command has printed so far. Present while running,
	// so the UI can show the current step instead of a bare spinner.
	Progress string `json:"progress,omitempty"`
	// ElapsedSeconds lets the UI say how long this has been going without
	// depending on the browser clock agreeing with the server's.
	ElapsedSeconds int `json:"elapsed_seconds,omitempty"`
}

// Runner serializes long-running MTProxyL operations. Mode switches, selfmask
// and restores take minutes and mutate host state, so they run in the
// background; only one at a time, or they would race over settings.conf.
type Runner struct {
	mu       sync.Mutex
	status   OperationStatus
	progress *Progress
}

func NewRunner() *Runner {
	return &Runner{status: OperationStatus{Phase: PhaseIdle}}
}

// Status returns the current operation snapshot.
func (r *Runner) Status() OperationStatus {
	r.mu.Lock()
	prog := r.progress
	st := r.status
	r.mu.Unlock()

	// Read the progress buffer outside the runner lock: it has its own, and the
	// running command writes into it constantly.
	if prog != nil {
		st.Progress = prog.String()
	}
	if !st.StartedAt.IsZero() {
		end := st.EndedAt
		if st.Phase == PhaseRunning {
			end = time.Now()
		}
		if !end.IsZero() {
			st.ElapsedSeconds = int(end.Sub(st.StartedAt).Seconds())
		}
	}
	return st
}

// Busy reports whether an operation is in flight.
func (r *Runner) Busy() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.status.Phase == PhaseRunning
}

// Dismiss clears a finished operation so the UI stops showing its log. The slot
// is shared and keeps the last result, so without this the panel comes back on
// every page load. A running operation is never dropped.
func (r *Runner) Dismiss() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.status.Phase == PhaseRunning {
		return false
	}
	r.status = OperationStatus{Phase: PhaseIdle}
	r.progress = nil
	return true
}

// Start launches fn in the background, false if another operation runs.
// fn gets a context detached from the request, so work survives the response.
func (r *Runner) Start(name string, fn func(ctx context.Context) (string, error)) bool {
	r.mu.Lock()
	if r.status.Phase == PhaseRunning {
		r.mu.Unlock()
		return false
	}
	r.status = OperationStatus{
		Phase:     PhaseRunning,
		Name:      name,
		StartedAt: time.Now(),
	}
	prog := &Progress{}
	r.progress = prog
	r.mu.Unlock()

	go func() {
		out, err := fn(WithProgress(context.Background(), prog))

		r.mu.Lock()
		defer r.mu.Unlock()
		r.status.Output = out
		r.status.EndedAt = time.Now()
		if err != nil {
			r.status.Phase = PhaseFailed
			r.status.Error = err.Error()
			return
		}
		r.status.Phase = PhaseDone
	}()

	return true
}
