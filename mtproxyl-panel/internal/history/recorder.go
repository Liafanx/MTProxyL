package history

import (
	"context"
	"log"
	"sync"
	"time"
)

const (
	MetricConnections        = "connections"
	MetricRefusals           = "refusals"
	MetricAvailable          = "available"
	MetricCurrentConnections = "current_connections"
	MetricActiveUsers        = "active_users"
	MetricActiveIPs          = "active_ips"
	MetricTraffic            = "traffic"

	StatsInterval = 5 * time.Second
	UsersInterval = 10 * time.Second
)

var knownMetrics = map[string]bool{
	MetricConnections: true, MetricRefusals: true, MetricAvailable: true,
	MetricCurrentConnections: true, MetricActiveUsers: true,
	MetricActiveIPs: true, MetricTraffic: true,
}

func IsMetric(name string) bool { return knownMetrics[name] }

// Fetcher — GET к telemt API с декодированием data; реализует proxy.TelemtProxy.
type Fetcher interface {
	GetJSON(ctx context.Context, path string, out any) error
}

type Recorder struct {
	ring  *Ring
	fetch Fetcher
	now   func() time.Time

	mu          sync.Mutex
	connections counter
	refusals    counter
	traffic     counter
	lastLog     map[string]time.Time
}

func NewRecorder(f Fetcher) *Recorder {
	return &Recorder{ring: NewRing(), fetch: f, now: time.Now, lastLog: make(map[string]time.Time)}
}

func (r *Recorder) Ring() *Ring { return r.ring }

// Run опрашивает движок до отмены контекста.
func (r *Recorder) Run(ctx context.Context) {
	r.PollStats(ctx)
	r.PollUsers(ctx)
	stats := time.NewTicker(StatsInterval)
	users := time.NewTicker(UsersInterval)
	defer stats.Stop()
	defer users.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-stats.C:
			r.PollStats(ctx)
		case <-users.C:
			r.PollUsers(ctx)
		}
	}
}

type classCount struct {
	Total uint64 `json:"total"`
}

type statsSummary struct {
	UptimeSeconds            float64      `json:"uptime_seconds"`
	ConnectionsTotal         uint64       `json:"connections_total"`
	ConnectionsBadTotal      uint64       `json:"connections_bad_total"`
	HandshakeTimeoutsTotal   uint64       `json:"handshake_timeouts_total"`
	HandshakeFailuresByClass []classCount `json:"handshake_failures_by_class"`
}

type connectionsSummary struct {
	Enabled bool `json:"enabled"`
	Data    *struct {
		Totals struct {
			CurrentConnections uint64 `json:"current_connections"`
			ActiveUsers        int64  `json:"active_users"`
		} `json:"totals"`
	} `json:"data"`
}

type userRow struct {
	TotalOctets     uint64 `json:"total_octets"`
	ActiveUniqueIPs int64  `json:"active_unique_ips"`
}

// PollStats пишет счётчики соединений и доступность движка.
func (r *Recorder) PollStats(ctx context.Context) {
	ts := r.now().Unix()
	var summary statsSummary
	if err := r.fetch.GetJSON(ctx, "/v1/stats/summary", &summary); err != nil {
		r.ring.Append(MetricAvailable, Point{TS: ts, V: 0})
		r.warn("stats", err)
		return
	}
	refused := summary.ConnectionsBadTotal
	if len(summary.HandshakeFailuresByClass) > 0 {
		for _, c := range summary.HandshakeFailuresByClass {
			refused += c.Total
		}
	} else {
		refused += summary.HandshakeTimeoutsTotal
	}
	r.mu.Lock()
	conn := r.connections.observe(summary.ConnectionsTotal, summary.UptimeSeconds)
	ref := r.refusals.observe(refused, summary.UptimeSeconds)
	r.mu.Unlock()
	r.ring.Append(MetricAvailable, Point{TS: ts, V: 1})
	r.ring.Append(MetricConnections, Point{TS: ts, V: conn})
	r.ring.Append(MetricRefusals, Point{TS: ts, V: ref})

	var live connectionsSummary
	if err := r.fetch.GetJSON(ctx, "/v1/runtime/connections/summary", &live); err != nil {
		r.warn("connections", err)
		return
	}
	if !live.Enabled || live.Data == nil {
		return
	}
	r.ring.Append(MetricCurrentConnections, Point{TS: ts, V: float64(live.Data.Totals.CurrentConnections)})
	r.ring.Append(MetricActiveUsers, Point{TS: ts, V: float64(live.Data.Totals.ActiveUsers)})
}

// PollUsers пишет активные IP и суммарный трафик по пользователям.
func (r *Recorder) PollUsers(ctx context.Context) {
	ts := r.now().Unix()
	var users []userRow
	if err := r.fetch.GetJSON(ctx, "/v1/users", &users); err != nil {
		r.warn("users", err)
		return
	}
	var ips int64
	var octets uint64
	for _, u := range users {
		ips += u.ActiveUniqueIPs
		octets += u.TotalOctets
	}
	r.mu.Lock()
	traffic := r.traffic.observe(octets, 0)
	r.mu.Unlock()
	r.ring.Append(MetricActiveIPs, Point{TS: ts, V: float64(ips)})
	r.ring.Append(MetricTraffic, Point{TS: ts, V: traffic})
}

// warn пишет ошибку источника не чаще раза в минуту.
func (r *Recorder) warn(source string, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	if last, ok := r.lastLog[source]; ok && now.Sub(last) < time.Minute {
		return
	}
	r.lastLog[source] = now
	log.Printf("history: %s: %v", source, err)
}
