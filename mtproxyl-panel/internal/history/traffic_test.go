package history

import (
	"path/filepath"
	"testing"
	"time"
)

func TestTrafficStoreBucketsAndSummary(t *testing.T) {
	start := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	st := NewTrafficStore("")
	ts := start.Unix()
	st.Observe(ts, map[string]uint64{"alice": 1000, "bob": 500})
	st.Observe(ts+10, map[string]uint64{"alice": 1600, "bob": 500})
	st.Observe(ts+900, map[string]uint64{"alice": 1700, "bob": 800})
	st.Observe(ts+910, map[string]uint64{"alice": 100, "bob": 800})
	st.Observe(ts+920, map[string]uint64{"alice": 150, "bob": 800})

	now := start.Add(20 * time.Minute)
	s, err := st.Summary("24h", "", now)
	if err != nil {
		t.Fatal(err)
	}
	if s.TotalBytes != 600+100+300+100+50 {
		t.Fatalf("total = %v", s.TotalBytes)
	}
	if s.Tier != "15m" || s.State != "partial" || len(s.Points) != 97 {
		t.Fatalf("summary = tier %s state %s points %d", s.Tier, s.State, len(s.Points))
	}
	var first, second float64
	for _, p := range s.Points {
		if p.TS == ts {
			first = p.V
		}
		if p.TS == ts+900 {
			second = p.V
		}
	}
	if first != 600 || second != 550 {
		t.Fatalf("buckets = %v, %v", first, second)
	}
	if len(s.TopUsers) != 2 || s.TopUsers[0].Username != "alice" || s.TopUsers[0].Bytes != 850 {
		t.Fatalf("top = %+v", s.TopUsers)
	}
	if s.PreviousBytes != nil {
		t.Fatalf("previous window must be unknown for a young store")
	}
	if s.TodayBytes != s.TotalBytes {
		t.Fatalf("today = %v, want %v", s.TodayBytes, s.TotalBytes)
	}

	u, err := st.Summary("7d", "bob", now)
	if err != nil || u.Username != "bob" || u.TotalBytes != 300 || u.Tier != "1h" || u.TopUsers != nil {
		t.Fatalf("user summary = %+v, %v", u, err)
	}
	if _, err := st.Summary("2y", "", now); err == nil {
		t.Fatal("unknown range accepted")
	}
	if s, _ := st.Summary("month", "", now); s.From != time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC).Unix() {
		t.Fatalf("month from = %d", s.From)
	}
}

func TestTrafficStoreRetentionAndPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "traffic.json")
	st := NewTrafficStore(path)
	base := int64(1_700_000_000)
	for i := int64(0); i < 4*86400/900; i++ {
		st.Observe(base+i*900, map[string]uint64{"alice": uint64(i * 10)})
	}
	u := st.users["alice"]
	if n := len(u.Tiers["15m"]); n < 190 || n > 194 {
		t.Fatalf("15m buckets = %d", n)
	}
	if n := len(u.Tiers["1h"]); n != 96 {
		t.Fatalf("1h buckets = %d", n)
	}
	if n := len(u.Tiers["1d"]); n < 4 || n > 5 {
		t.Fatalf("1d buckets = %d", n)
	}
	if err := st.Save(); err != nil {
		t.Fatal(err)
	}
	if err := st.Save(); err != nil {
		t.Fatal(err)
	}
	loaded := NewTrafficStore(path)
	if err := loaded.Load(); err != nil {
		t.Fatal(err)
	}
	if loaded.observedSince != base || len(loaded.users["alice"].Tiers["1d"]) != len(u.Tiers["1d"]) {
		t.Fatalf("loaded = since %d users %+v", loaded.observedSince, loaded.users["alice"].Tiers["1d"])
	}
	now := time.Unix(base+4*86400, 0)
	a, _ := st.Summary("30d", "", now)
	b, _ := loaded.Summary("30d", "", now)
	if a.TotalBytes != b.TotalBytes || a.TotalBytes == 0 {
		t.Fatalf("totals differ after reload: %v vs %v", a.TotalBytes, b.TotalBytes)
	}
	if b.PreviousBytes != nil {
		t.Fatalf("30d previous window must be unknown after 4 days: %v", *b.PreviousBytes)
	}
	if d, _ := loaded.Summary("24h", "", now); d.PreviousBytes == nil || *d.PreviousBytes <= 0 || d.State != "ready" {
		t.Fatalf("24h summary = %+v", d)
	}
	empty := NewTrafficStore(filepath.Join(t.TempDir(), "none.json"))
	if err := empty.Load(); err != nil {
		t.Fatal(err)
	}
	if s, _ := empty.Summary("24h", "", now); s.State != "empty" || len(s.Points) == 0 {
		t.Fatalf("empty store summary = %+v", s)
	}
}
