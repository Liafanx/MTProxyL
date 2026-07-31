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
}

// Runner serializes long-running MTProxyL operations.
//
// Mode switches, selfmask provisioning and restores take minutes and mutate
// host state, so they run in the background while the UI polls for status.
// Only one may run at a time: concurrent invocations would race over the same
// settings.conf and container.
type Runner struct {
	mu     sync.Mutex
	status OperationStatus
}

func NewRunner() *Runner {
	return &Runner{status: OperationStatus{Phase: PhaseIdle}}
}

// Status returns the current operation snapshot.
func (r *Runner) Status() OperationStatus {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.status
}

// Busy reports whether an operation is in flight.
func (r *Runner) Busy() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.status.Phase == PhaseRunning
}

// Start launches fn in the background under the given name.
//
// It returns false if another operation is already running. fn receives a
// context detached from the HTTP request, so the work survives the response.
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
	r.mu.Unlock()

	go func() {
		out, err := fn(context.Background())

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
