package history

import (
	"context"
	"log"
	"strconv"
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

	StatsInterval        = 5 * time.Second
	UsersInterval        = 10 * time.Second
	FingerprintsInterval = time.Minute
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
	ring         *Ring
	fetch        Fetcher
	now          func() time.Time
	traffic      *TrafficStore
	fingerprints *FingerprintStore
	limitsPath   string

	mu           sync.Mutex
	limits       Limits
	connections  counter
	refusals     counter
	trafficTotal counter
	lastLog      map[string]time.Time
	edge         gateState
}

// gateState — последнее известное состояние гейта runtime edge.
type gateState struct {
	seen    bool
	enabled bool
	reason  string
}

func NewRecorder(f Fetcher) *Recorder {
	return &Recorder{ring: NewRing(), fetch: f, now: time.Now, lastLog: make(map[string]time.Time), limits: DefaultLimits()}
}

// WithTrafficStore включает долговременную историю трафика по пользователям.
func (r *Recorder) WithTrafficStore(t *TrafficStore) *Recorder {
	r.traffic = t
	return r
}

// WithFingerprintStore включает накопление TLS-отпечатков.
func (r *Recorder) WithFingerprintStore(f *FingerprintStore) *Recorder {
	r.fingerprints = f
	return r
}

// WithLimits задаёт пределы хранения и файл, где они сохраняются.
func (r *Recorder) WithLimits(path string, l Limits) *Recorder {
	r.limitsPath = path
	r.applyLimits(l)
	return r
}

func (r *Recorder) Ring() *Ring                     { return r.ring }
func (r *Recorder) Traffic() *TrafficStore          { return r.traffic }
func (r *Recorder) Fingerprints() *FingerprintStore { return r.fingerprints }

func (r *Recorder) Limits() Limits {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.limits
}

// SetLimits применяет пределы к хранилищам и сохраняет их на диск.
func (r *Recorder) SetLimits(l Limits) error {
	if err := l.Validate(); err != nil {
		return err
	}
	r.applyLimits(l)
	return SaveLimits(r.limitsPath, l)
}

func (r *Recorder) applyLimits(l Limits) {
	r.mu.Lock()
	r.limits = l
	r.mu.Unlock()
	if r.traffic != nil {
		r.traffic.SetMaxUsers(l.TrafficMaxUsers)
	}
	if r.fingerprints != nil {
		r.fingerprints.SetLimits(l.FingerprintsMaxRecords, l.FingerprintsRetentionDays, r.now().Unix())
	}
}

// Run опрашивает движок до отмены контекста.
func (r *Recorder) Run(ctx context.Context) {
	r.PollStats(ctx)
	r.PollUsers(ctx)
	r.PollFingerprints(ctx)
	stats := time.NewTicker(StatsInterval)
	users := time.NewTicker(UsersInterval)
	fingerprints := time.NewTicker(FingerprintsInterval)
	save := time.NewTicker(time.Minute)
	defer stats.Stop()
	defer users.Stop()
	defer fingerprints.Stop()
	defer save.Stop()
	for {
		select {
		case <-ctx.Done():
			r.Save()
			return
		case <-stats.C:
			r.PollStats(ctx)
		case <-users.C:
			r.PollUsers(ctx)
		case <-fingerprints.C:
			r.PollFingerprints(ctx)
		case <-save.C:
			r.Save()
		}
	}
}

// Save сбрасывает изменённые хранилища на диск.
func (r *Recorder) Save() {
	if r.traffic != nil {
		if err := r.traffic.Save(); err != nil {
			r.warn("traffic-save", err)
		}
	}
	if r.fingerprints != nil {
		if err := r.fingerprints.Save(); err != nil {
			r.warn("fingerprints-save", err)
		}
	}
}

type fingerprintsGate struct {
	Enabled bool                `json:"enabled"`
	Reason  string              `json:"reason"`
	Data    *EngineFingerprints `json:"data"`
}

// PollFingerprints сливает снимок отпечатков движка в хранилище панели.
func (r *Recorder) PollFingerprints(ctx context.Context) {
	if r.fingerprints == nil {
		return
	}
	var gate fingerprintsGate
	if err := r.fetch.GetJSON(ctx, "/v1/runtime/tls-fingerprints?limit="+strconv.Itoa(FingerprintPollLimit), &gate); err != nil {
		r.warn("fingerprints", err)
		return
	}
	if !gate.Enabled || gate.Data == nil {
		r.fingerprints.SetGate(false, gate.Reason)
		return
	}
	r.fingerprints.Merge(r.now().Unix(), gate.Data)
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
	Enabled bool   `json:"enabled"`
	Reason  string `json:"reason"`
	Data    *struct {
		Totals struct {
			CurrentConnections uint64 `json:"current_connections"`
			ActiveUsers        int64  `json:"active_users"`
		} `json:"totals"`
	} `json:"data"`
}

type userRow struct {
	Username        string `json:"username"`
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
	r.mu.Lock()
	r.edge = gateState{seen: true, enabled: live.Enabled && live.Data != nil, reason: live.Reason}
	r.mu.Unlock()
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
	perUser := make(map[string]uint64, len(users))
	for _, u := range users {
		ips += u.ActiveUniqueIPs
		octets += u.TotalOctets
		if u.Username != "" {
			perUser[u.Username] += u.TotalOctets
		}
	}
	r.mu.Lock()
	traffic := r.trafficTotal.observe(octets, 0)
	r.mu.Unlock()
	if r.traffic != nil {
		r.traffic.Observe(ts, perUser)
	}
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

// EdgeGate: известно ли состояние runtime edge и включён ли он.
func (r *Recorder) EdgeGate() (seen, enabled bool, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.edge.seen, r.edge.enabled, r.edge.reason
}
