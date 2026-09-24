package history

import (
	"path/filepath"
	"testing"
	"time"
)

func engineSnapshot(ip string, first, last int64, total, auth, bad uint64) *EngineFingerprints {
	row := EngineFingerprintRow{Scope: ip, JA3: "ja3-" + ip, JA4: "t13d", Total: total, AuthSuccess: auth, BadOrProbe: bad, FirstSeen: first, LastSeen: last}
	fp := row
	fp.Scope = ""
	return &EngineFingerprints{Limit: 500, RetentionSecs: 3600, Capacity: 4096, ByIP: []EngineFingerprintRow{row}, ByFingerprint: []EngineFingerprintRow{fp}}
}

func TestFingerprintStoreMergeKeepsPastWindows(t *testing.T) {
	st := NewFingerprintStore("")
	st.Merge(1000, engineSnapshot("1.1.1.1", 900, 1000, 10, 8, 2))
	st.Merge(1060, engineSnapshot("1.1.1.1", 900, 1060, 15, 12, 3))
	rows := st.Rows("by_ip")
	if len(rows) != 1 || rows[0].Total != 15 || rows[0].AuthSuccess != 12 || rows[0].BadOrProbe != 3 {
		t.Fatalf("same window must replace counters: %+v", rows)
	}
	st.Merge(1120, engineSnapshot("1.1.1.1", 1100, 1120, 4, 4, 0))
	rows = st.Rows("by_ip")
	if rows[0].Total != 19 || rows[0].AuthSuccess != 16 || rows[0].BadOrProbe != 3 || rows[0].FirstSeen != 900 || rows[0].LastSeen != 1120 {
		t.Fatalf("new window must add to base: %+v", rows[0])
	}
	if fp := st.Rows("by_fingerprint"); len(fp) != 1 || fp[0].Key != "t13d" || fp[0].Total != 19 {
		t.Fatalf("by_fingerprint keyed by ja4: %+v", fp)
	}
	if seen, enabled, _ := st.Gate(); !seen || !enabled {
		t.Fatal("gate must be open after merge")
	}
	if e := st.Engine(); e.Capacity != 4096 || e.FetchedAt != 1120 {
		t.Fatalf("engine meta = %+v", e)
	}
}

func TestFingerprintStoreLimitsAndPrune(t *testing.T) {
	st := NewFingerprintStore("")
	st.SetLimits(2, 1, 0)
	for i, ip := range []string{"1.1.1.1", "2.2.2.2", "3.3.3.3"} {
		st.Merge(int64(1000+i), engineSnapshot(ip, int64(1000+i), int64(1000+i), 1, 1, 0))
	}
	counts := st.Counts()
	if counts["by_ip"] != 2 {
		t.Fatalf("max records: %v", counts)
	}
	for _, r := range st.Rows("by_ip") {
		if r.Key == "1.1.1.1" {
			t.Fatal("oldest row must be evicted")
		}
	}
	st.Merge(1002+3*86400, engineSnapshot("9.9.9.9", 1002+3*86400, 1002+3*86400, 1, 1, 0))
	if rows := st.Rows("by_ip"); len(rows) != 1 || rows[0].Key != "9.9.9.9" {
		t.Fatalf("retention must drop stale rows: %+v", rows)
	}
	st.Clear()
	if st.Counts()["by_ip"] != 0 {
		t.Fatal("clear")
	}
}

func TestFingerprintStoreSaveLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fp.json")
	st := NewFingerprintStore(path)
	st.Merge(1000, engineSnapshot("1.1.1.1", 900, 1000, 10, 8, 2))
	st.Merge(1100, engineSnapshot("1.1.1.1", 1050, 1100, 1, 1, 0))
	if err := st.Save(); err != nil {
		t.Fatal(err)
	}
	if FileSize(path) == 0 {
		t.Fatal("file must exist")
	}
	loaded := NewFingerprintStore(path)
	if err := loaded.Load(); err != nil {
		t.Fatal(err)
	}
	rows := loaded.Rows("by_ip")
	if len(rows) != 1 || rows[0].Key != "1.1.1.1" || rows[0].Total != 11 {
		t.Fatalf("loaded = %+v", rows)
	}
	loaded.Merge(1200, engineSnapshot("1.1.1.1", 1050, 1200, 5, 5, 0))
	if rows := loaded.Rows("by_ip"); rows[0].Total != 15 {
		t.Fatalf("window continues after reload: %+v", rows[0])
	}
}

func TestQueryFingerprints(t *testing.T) {
	rows := []FingerprintRow{
		{Key: "b", Total: 5, BadOrProbe: 1, LastSeen: 3, Country: "DE", CountryName: "Germany"},
		{Key: "a", Total: 9, LastSeen: 1},
		{Key: "c", Total: 5, BadOrProbe: 4, LastSeen: 2, CountryName: "Russia"},
	}
	page, total := QueryFingerprints(rows, FingerprintQuery{Sort: "total", Desc: true, Limit: 2})
	if total != 3 || len(page) != 2 || page[0].Key != "a" || page[1].Key != "b" {
		t.Fatalf("desc total: %+v", page)
	}
	page, total = QueryFingerprints(rows, FingerprintQuery{Sort: "last_seen", Offset: 2})
	if total != 3 || len(page) != 1 || page[0].Key != "b" {
		t.Fatalf("offset: %+v", page)
	}
	page, total = QueryFingerprints(rows, FingerprintQuery{Sort: "bad_or_probe", Desc: true, Suspicious: true})
	if total != 2 || page[0].Key != "c" {
		t.Fatalf("suspicious: %+v", page)
	}
	page, total = QueryFingerprints(rows, FingerprintQuery{Search: "germ"})
	if total != 1 || page[0].Key != "b" {
		t.Fatalf("search: %+v", page)
	}
	if _, total = QueryFingerprints(rows, FingerprintQuery{Offset: 99}); total != 3 {
		t.Fatal("offset beyond end")
	}
}

func TestLimitsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "limits.json")
	l, err := LoadLimits(path)
	if err != nil || l != DefaultLimits() {
		t.Fatalf("defaults: %+v %v", l, err)
	}
	want := Limits{TrafficMaxUsers: 10, FingerprintsMaxRecords: 100, FingerprintsRetentionDays: 7}
	if err := SaveLimits(path, want); err != nil {
		t.Fatal(err)
	}
	if got, err := LoadLimits(path); err != nil || got != want {
		t.Fatalf("roundtrip: %+v %v", got, err)
	}
	if (Limits{TrafficMaxUsers: -1}).Validate() == nil || (Limits{FingerprintsRetentionDays: 5000}).Validate() == nil {
		t.Fatal("validate")
	}
}

func TestTrafficStoreMaxUsers(t *testing.T) {
	st := NewTrafficStore("")
	st.Observe(1000, map[string]uint64{"a": 1, "b": 1, "c": 1})
	st.Observe(1010, map[string]uint64{"a": 5, "b": 5, "c": 5})
	st.Observe(1020, map[string]uint64{"a": 9, "c": 9})
	st.SetMaxUsers(2)
	if st.UsersCount() != 2 {
		t.Fatalf("users = %d", st.UsersCount())
	}
	s, err := st.Summary("24h", "b", time.Unix(1030, 0))
	if err != nil || s.TotalBytes != 0 {
		t.Fatalf("b must be evicted as least recently active: %+v %v", s, err)
	}
	if s, _ = st.Summary("24h", "a", time.Unix(1030, 0)); s.TotalBytes != 8 {
		t.Fatalf("a stays: %+v", s)
	}
	st.Clear("")
	if st.UsersCount() != 0 {
		t.Fatal("clear")
	}
}
