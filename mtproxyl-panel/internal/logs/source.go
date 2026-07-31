package logs

import "context"

const DefaultSince = "1h"

// LogOptions controls log history and stream start behavior.
type LogOptions struct {
	Since string
}

// LogSource provides access to service logs.
type LogSource interface {
	// Tail returns the last n lines.
	Tail(ctx context.Context, n int, opts LogOptions) ([]string, error)
	// Stream returns a channel that emits new log lines in real-time.
	// The channel is closed when ctx is cancelled or the source process exits.
	Stream(ctx context.Context, opts LogOptions) (<-chan string, error)
	// Name returns the source type ("journalctl" or "docker").
	Name() string
}

// ClampLines clamps n to [1, 5000].
func ClampLines(n int) int {
	if n < 1 {
		return 1
	}
	if n > 5000 {
		return 5000
	}
	return n
}

// NormalizeSince maps UI values to a safe internal enum.
func NormalizeSince(v string) string {
	switch v {
	case "1h", "2h", "12h", "24h", "7d", "all":
		return v
	default:
		return DefaultSince
	}
}

func journalctlSinceArg(v string) string {
	switch NormalizeSince(v) {
	case "1h":
		return "-1 hour"
	case "2h":
		return "-2 hours"
	case "12h":
		return "-12 hours"
	case "24h":
		return "-24 hours"
	case "7d":
		return "-7 days"
	default:
		return ""
	}
}

func dockerSinceArg(v string) string {
	switch NormalizeSince(v) {
	case "1h":
		return "1h"
	case "2h":
		return "2h"
	case "12h":
		return "12h"
	case "24h":
		return "24h"
	case "7d":
		return "168h"
	default:
		return ""
	}
}
