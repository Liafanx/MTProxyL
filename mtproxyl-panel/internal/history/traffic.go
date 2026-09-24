package history

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Тиры хранения трафика: корзина и глубина.
var trafficTiers = []struct {
	name      string
	bucket    int64
	retention int64
}{
	{"15m", 900, 2 * 86400},
	{"1h", 3600, 31 * 86400},
	{"1d", 86400, 400 * 86400},
}

var trafficRanges = map[string]struct {
	window int64
	tier   string
}{
	"24h":   {86400, "15m"},
	"7d":    {7 * 86400, "1h"},
	"30d":   {30 * 86400, "1d"},
	"1y":    {365 * 86400, "1d"},
	"month": {0, "1d"},
}

func TrafficRanges() []string { return []string{"24h", "7d", "30d", "1y", "month"} }

type bucket struct {
	TS int64
	V  float64
}

func (b bucket) MarshalJSON() ([]byte, error) { return json.Marshal([2]float64{float64(b.TS), b.V}) }

func (b *bucket) UnmarshalJSON(data []byte) error {
	var raw [2]float64
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	b.TS = int64(raw[0])
	b.V = raw[1]
	return nil
}

type userTraffic struct {
	Tiers    map[string][]bucket `json:"tiers"`
	LastSeen int64               `json:"last_seen,omitempty"`
	last     counter
}

type trafficFile struct {
	Version       int                     `json:"version"`
	ObservedSince int64                   `json:"observed_since"`
	ObservedUntil int64                   `json:"observed_until"`
	Users         map[string]*userTraffic `json:"users"`
}

// TrafficStore копит байты по пользователям в трёх тирах и хранит их в JSON.
type TrafficStore struct {
	mu            sync.Mutex
	path          string
	users         map[string]*userTraffic
	observedSince int64
	observedUntil int64
	maxUsers      int
	dirty         bool
}

func NewTrafficStore(path string) *TrafficStore {
	return &TrafficStore{path: path, users: make(map[string]*userTraffic)}
}

func (t *TrafficStore) Path() string { return t.path }

// SetMaxUsers ограничивает число пользователей в истории; 0 — без предела.
// Лишние — те, чей трафик наблюдался раньше всех.
func (t *TrafficStore) SetMaxUsers(n int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.maxUsers = n
	t.pruneLocked()
}

func (t *TrafficStore) MaxUsers() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.maxUsers
}

func (t *TrafficStore) UsersCount() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.users)
}

func (t *TrafficStore) Observed() (since, until int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.observedSince, t.observedUntil
}

// Clear удаляет историю всех пользователей или одного.
func (t *TrafficStore) Clear(username string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if username == "" {
		t.users = make(map[string]*userTraffic)
		t.observedSince, t.observedUntil = 0, 0
	} else {
		delete(t.users, username)
	}
	t.dirty = true
}

func (t *TrafficStore) pruneLocked() {
	if t.maxUsers <= 0 || len(t.users) <= t.maxUsers {
		return
	}
	names := make([]string, 0, len(t.users))
	for name := range t.users {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		a, b := t.users[names[i]], t.users[names[j]]
		if a.LastSeen != b.LastSeen {
			return a.LastSeen < b.LastSeen
		}
		return names[i] < names[j]
	})
	for _, name := range names[:len(t.users)-t.maxUsers] {
		delete(t.users, name)
	}
	t.dirty = true
}

// Load читает файл, отсутствие файла — не ошибка.
func (t *TrafficStore) Load() error {
	if t.path == "" {
		return nil
	}
	data, err := os.ReadFile(t.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var f trafficFile
	if err := json.Unmarshal(data, &f); err != nil {
		return fmt.Errorf("traffic history %s: %w", t.path, err)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.observedSince = f.ObservedSince
	t.observedUntil = f.ObservedUntil
	t.users = make(map[string]*userTraffic, len(f.Users))
	for name, u := range f.Users {
		if u == nil || name == "" {
			continue
		}
		if u.Tiers == nil {
			u.Tiers = make(map[string][]bucket)
		}
		for tier, list := range u.Tiers {
			sort.Slice(list, func(i, j int) bool { return list[i].TS < list[j].TS })
			u.Tiers[tier] = list
			if n := len(list); n > 0 && list[n-1].TS > u.LastSeen {
				u.LastSeen = list[n-1].TS
			}
		}
		t.users[name] = u
	}
	return nil
}

// Save записывает файл атомарно; без изменений ничего не делает.
func (t *TrafficStore) Save() error {
	t.mu.Lock()
	if !t.dirty || t.path == "" {
		t.mu.Unlock()
		return nil
	}
	f := trafficFile{Version: 1, ObservedSince: t.observedSince, ObservedUntil: t.observedUntil, Users: t.users}
	data, err := json.Marshal(f)
	t.dirty = false
	t.mu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(t.path), 0o750); err != nil {
		return err
	}
	tmp := t.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, t.path)
}

// Observe принимает накопленные байты по пользователям на момент ts.
// Первое наблюдение пользователя — базовая линия, падение суммы — сброс.
func (t *TrafficStore) Observe(ts int64, totals map[string]uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.observedSince == 0 {
		t.observedSince = ts
	}
	if ts > t.observedUntil {
		t.observedUntil = ts
	}
	for name, octets := range totals {
		if name == "" {
			continue
		}
		u := t.users[name]
		if u == nil {
			u = &userTraffic{Tiers: make(map[string][]bucket)}
			t.users[name] = u
		}
		before := u.last.total
		after := u.last.observe(octets, 0)
		delta := after - before
		if delta <= 0 {
			continue
		}
		for _, tier := range trafficTiers {
			u.Tiers[tier.name] = addToBucket(u.Tiers[tier.name], ts-ts%tier.bucket, delta, ts-tier.retention)
		}
		u.LastSeen = ts
		t.dirty = true
	}
	t.pruneLocked()
}

func addToBucket(list []bucket, start int64, delta float64, cutoff int64) []bucket {
	n := len(list)
	if n > 0 && list[n-1].TS == start {
		list[n-1].V += delta
	} else if n == 0 || list[n-1].TS < start {
		list = append(list, bucket{TS: start, V: delta})
	} else {
		i := sort.Search(n, func(i int) bool { return list[i].TS >= start })
		if i < n && list[i].TS == start {
			list[i].V += delta
		} else {
			list = append(list, bucket{})
			copy(list[i+1:], list[i:])
			list[i] = bucket{TS: start, V: delta}
		}
	}
	first := sort.Search(len(list), func(i int) bool { return list[i].TS >= cutoff })
	if first > 0 {
		list = append([]bucket(nil), list[first:]...)
	}
	return list
}

type TrafficPoint struct {
	TS   int64   `json:"ts"`
	V    float64 `json:"v"`
	Tier string  `json:"tier"`
}

type TrafficRank struct {
	Username string  `json:"username"`
	Bytes    float64 `json:"bytes"`
}

type TrafficSummary struct {
	Range         string         `json:"range"`
	Tier          string         `json:"tier"`
	State         string         `json:"state"`
	From          int64          `json:"requested_from_epoch_secs"`
	To            int64          `json:"requested_to_epoch_secs"`
	ObservedSince int64          `json:"observed_since_epoch_secs,omitempty"`
	ObservedUntil int64          `json:"observed_until_epoch_secs,omitempty"`
	TotalBytes    float64        `json:"total_bytes"`
	PreviousBytes *float64       `json:"previous_total_bytes,omitempty"`
	TodayBytes    float64        `json:"today_bytes"`
	Points        []TrafficPoint `json:"points"`
	TopUsers      []TrafficRank  `json:"top_users,omitempty"`
	Username      string         `json:"username,omitempty"`
}

func resolveTrafficRange(rng string, now time.Time) (from, to int64, tier string, err error) {
	r, ok := trafficRanges[rng]
	if !ok {
		return 0, 0, "", fmt.Errorf("unknown range %q", rng)
	}
	to = now.Unix()
	if rng == "month" {
		y, m, _ := now.UTC().Date()
		from = time.Date(y, m, 1, 0, 0, 0, 0, time.UTC).Unix()
	} else {
		from = to - r.window
	}
	return from, to, r.tier, nil
}

func tierBucket(tier string) int64 {
	for _, t := range trafficTiers {
		if t.name == tier {
			return t.bucket
		}
	}
	return 900
}

// sumRange суммирует корзины тира пользователя внутри [from, to).
func (u *userTraffic) sumRange(tier string, from, to int64) float64 {
	var total float64
	for _, b := range u.Tiers[tier] {
		if b.TS >= from && b.TS < to {
			total += b.V
		}
	}
	return total
}

// Summary — сводка по всем пользователям или одному, если username задан.
func (t *TrafficStore) Summary(rng, username string, now time.Time) (TrafficSummary, error) {
	from, to, tier, err := resolveTrafficRange(rng, now)
	if err != nil {
		return TrafficSummary{}, err
	}
	step := tierBucket(tier)
	gridFrom := from - from%step
	t.mu.Lock()
	defer t.mu.Unlock()

	sums := make(map[int64]float64)
	ranks := make([]TrafficRank, 0, len(t.users))
	var total, previous float64
	y, m, d := now.UTC().Date()
	todayStart := time.Date(y, m, d, 0, 0, 0, 0, time.UTC).Unix()
	var today float64
	window := to - from
	for name, u := range t.users {
		if username != "" && name != username {
			continue
		}
		var userTotal float64
		for _, b := range u.Tiers[tier] {
			if b.TS >= gridFrom && b.TS <= to {
				sums[b.TS] += b.V
				userTotal += b.V
			}
		}
		total += userTotal
		previous += u.sumRange(tier, from-window, from)
		today += u.sumRange("15m", todayStart, to+1)
		if userTotal > 0 {
			ranks = append(ranks, TrafficRank{Username: name, Bytes: userTotal})
		}
	}
	points := make([]TrafficPoint, 0, (to-gridFrom)/step+1)
	for ts := gridFrom; ts <= to; ts += step {
		points = append(points, TrafficPoint{TS: ts, V: sums[ts], Tier: tier})
	}
	s := TrafficSummary{
		Range: rng, Tier: tier, From: from, To: to,
		ObservedSince: t.observedSince, ObservedUntil: t.observedUntil,
		TotalBytes: total, TodayBytes: today, Points: points, Username: username,
	}
	if username == "" {
		sort.Slice(ranks, func(i, j int) bool { return ranks[i].Bytes > ranks[j].Bytes })
		if len(ranks) > 5 {
			ranks = ranks[:5]
		}
		s.TopUsers = ranks
	}
	if t.observedSince > 0 && t.observedSince <= from-window && rng != "month" {
		s.PreviousBytes = &previous
	}
	switch {
	case t.observedSince == 0:
		s.State = "empty"
	case t.observedSince > from+step:
		s.State = "partial"
	default:
		s.State = "ready"
	}
	return s, nil
}
