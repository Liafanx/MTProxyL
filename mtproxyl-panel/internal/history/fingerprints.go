package history

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

const (
	DefaultFingerprintMaxRecords    = 2000
	DefaultFingerprintRetentionDays = 30
	FingerprintPollLimit            = 500
)

var FingerprintScopes = []string{"by_fingerprint", "by_ip", "by_cidr", "by_user"}

func IsFingerprintScope(scope string) bool {
	for _, s := range FingerprintScopes {
		if s == scope {
			return true
		}
	}
	return false
}

// EngineFingerprintRow — строка ответа движка /v1/runtime/tls-fingerprints.
type EngineFingerprintRow struct {
	Scope       string `json:"scope,omitempty"`
	JA3         string `json:"ja3"`
	JA3Raw      string `json:"ja3_raw"`
	JA4         string `json:"ja4"`
	JA4Raw      string `json:"ja4_raw"`
	Total       uint64 `json:"total"`
	AuthSuccess uint64 `json:"auth_success"`
	BadOrProbe  uint64 `json:"bad_or_probe"`
	FirstSeen   int64  `json:"first_seen_epoch_secs"`
	LastSeen    int64  `json:"last_seen_epoch_secs"`
}

// EngineFingerprints — data гейта /v1/runtime/tls-fingerprints.
type EngineFingerprints struct {
	Limit           int                    `json:"limit"`
	RetentionSecs   uint64                 `json:"retention_secs"`
	Capacity        int                    `json:"capacity"`
	DroppedTotal    uint64                 `json:"dropped_total"`
	ParseErrorTotal uint64                 `json:"parse_error_total"`
	ByFingerprint   []EngineFingerprintRow `json:"by_fingerprint"`
	ByIP            []EngineFingerprintRow `json:"by_ip"`
	ByCIDR          []EngineFingerprintRow `json:"by_cidr"`
	ByUser          []EngineFingerprintRow `json:"by_user"`
}

func (e *EngineFingerprints) rows(scope string) []EngineFingerprintRow {
	switch scope {
	case "by_fingerprint":
		return e.ByFingerprint
	case "by_ip":
		return e.ByIP
	case "by_cidr":
		return e.ByCIDR
	case "by_user":
		return e.ByUser
	}
	return nil
}

// FingerprintRow — накопленная панелью строка: база прошлых окон движка
// плюс текущий снимок. Ключ — отпечаток JA4, IP, подсеть или пользователь.
type FingerprintRow struct {
	Key         string `json:"key"`
	JA3         string `json:"ja3"`
	JA3Raw      string `json:"ja3_raw"`
	JA4         string `json:"ja4"`
	JA4Raw      string `json:"ja4_raw"`
	Total       uint64 `json:"total"`
	AuthSuccess uint64 `json:"auth_success"`
	BadOrProbe  uint64 `json:"bad_or_probe"`
	FirstSeen   int64  `json:"first_seen_epoch_secs"`
	LastSeen    int64  `json:"last_seen_epoch_secs"`

	Country     string `json:"country,omitempty"`
	CountryName string `json:"country_name,omitempty"`
	City        string `json:"city,omitempty"`
	ASNOrg      string `json:"asn_org,omitempty"`
}

type storedFingerprint struct {
	FingerprintRow
	EngFirst int64     `json:"eng_first"`
	EngTotal uint64    `json:"eng_total"`
	EngAuth  uint64    `json:"eng_auth"`
	EngBad   uint64    `json:"eng_bad"`
	Base     [3]uint64 `json:"base"`
}

func (s *storedFingerprint) refresh() {
	s.Total = s.Base[0] + s.EngTotal
	s.AuthSuccess = s.Base[1] + s.EngAuth
	s.BadOrProbe = s.Base[2] + s.EngBad
}

type fingerprintFile struct {
	Version int                                      `json:"version"`
	Since   int64                                    `json:"observed_since"`
	Until   int64                                    `json:"observed_until"`
	Scopes  map[string]map[string]*storedFingerprint `json:"scopes"`
}

// FingerprintStore копит отпечатки TLS дольше окна движка и хранит их в JSON.
type FingerprintStore struct {
	mu            sync.Mutex
	path          string
	scopes        map[string]map[string]*storedFingerprint
	maxRecords    int
	retentionDays int
	since, until  int64
	dirty         bool
	gate          gateState
	engine        EngineMeta
}

// EngineMeta — параметры хранилища самого движка из последнего ответа.
type EngineMeta struct {
	Limit           int    `json:"limit"`
	RetentionSecs   uint64 `json:"retention_secs"`
	Capacity        int    `json:"capacity"`
	DroppedTotal    uint64 `json:"dropped_total"`
	ParseErrorTotal uint64 `json:"parse_error_total"`
	FetchedAt       int64  `json:"fetched_at_epoch_secs,omitempty"`
}

func NewFingerprintStore(path string) *FingerprintStore {
	s := &FingerprintStore{path: path, maxRecords: DefaultFingerprintMaxRecords, retentionDays: DefaultFingerprintRetentionDays}
	s.scopes = make(map[string]map[string]*storedFingerprint)
	for _, scope := range FingerprintScopes {
		s.scopes[scope] = make(map[string]*storedFingerprint)
	}
	return s
}

func (s *FingerprintStore) Path() string { return s.path }

// SetLimits: предел записей на каждую группу и глубина в днях; 0 — без предела.
func (s *FingerprintStore) SetLimits(maxRecords, retentionDays int, now int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.maxRecords, s.retentionDays = maxRecords, retentionDays
	s.pruneLocked(now)
}

func (s *FingerprintStore) Limits() (maxRecords, retentionDays int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.maxRecords, s.retentionDays
}

func (s *FingerprintStore) Load() error {
	if s.path == "" {
		return nil
	}
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var f fingerprintFile
	if err := json.Unmarshal(data, &f); err != nil {
		return fmt.Errorf("tls fingerprints %s: %w", s.path, err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.since, s.until = f.Since, f.Until
	for _, scope := range FingerprintScopes {
		rows := f.Scopes[scope]
		if rows == nil {
			rows = make(map[string]*storedFingerprint)
		}
		for key, row := range rows {
			if row == nil || key == "" {
				delete(rows, key)
				continue
			}
			row.Key = key
			row.refresh()
		}
		s.scopes[scope] = rows
	}
	return nil
}

func (s *FingerprintStore) Save() error {
	s.mu.Lock()
	if !s.dirty || s.path == "" {
		s.mu.Unlock()
		return nil
	}
	data, err := json.Marshal(fingerprintFile{Version: 1, Since: s.since, Until: s.until, Scopes: s.scopes})
	s.dirty = false
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o750); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Merge накладывает снимок движка. Строка с тем же first_seen — то же окно
// движка, счётчики заменяются; новое first_seen — прошлое окно уходит в базу.
func (s *FingerprintStore) Merge(now int64, e *EngineFingerprints) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gate = gateState{seen: true, enabled: true}
	s.engine = EngineMeta{Limit: e.Limit, RetentionSecs: e.RetentionSecs, Capacity: e.Capacity, DroppedTotal: e.DroppedTotal, ParseErrorTotal: e.ParseErrorTotal, FetchedAt: now}
	if s.since == 0 {
		s.since = now
	}
	if now > s.until {
		s.until = now
	}
	for _, scope := range FingerprintScopes {
		rows := s.scopes[scope]
		for _, r := range e.rows(scope) {
			key := r.Scope
			if scope == "by_fingerprint" || key == "" {
				key = r.JA4
			}
			if key == "" {
				continue
			}
			st := rows[key]
			if st == nil {
				st = &storedFingerprint{FingerprintRow: FingerprintRow{Key: key, FirstSeen: r.FirstSeen}}
				rows[key] = st
			} else if r.FirstSeen != st.EngFirst || r.Total < st.EngTotal {
				st.Base[0] += st.EngTotal
				st.Base[1] += st.EngAuth
				st.Base[2] += st.EngBad
			}
			st.JA3, st.JA3Raw, st.JA4, st.JA4Raw = r.JA3, r.JA3Raw, r.JA4, r.JA4Raw
			st.EngFirst, st.EngTotal, st.EngAuth, st.EngBad = r.FirstSeen, r.Total, r.AuthSuccess, r.BadOrProbe
			if r.FirstSeen > 0 && (st.FirstSeen == 0 || r.FirstSeen < st.FirstSeen) {
				st.FirstSeen = r.FirstSeen
			}
			if r.LastSeen > st.LastSeen {
				st.LastSeen = r.LastSeen
			}
			st.refresh()
			s.dirty = true
		}
	}
	s.pruneLocked(now)
}

// SetGate запоминает, что гейт движка закрыт: данных нет, причина известна.
func (s *FingerprintStore) SetGate(enabled bool, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gate = gateState{seen: true, enabled: enabled, reason: reason}
}

func (s *FingerprintStore) Gate() (seen, enabled bool, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gate.seen, s.gate.enabled, s.gate.reason
}

func (s *FingerprintStore) Engine() EngineMeta {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.engine
}

func (s *FingerprintStore) pruneLocked(now int64) {
	cutoff := int64(0)
	if s.retentionDays > 0 {
		cutoff = now - int64(s.retentionDays)*86400
	}
	for _, scope := range FingerprintScopes {
		rows := s.scopes[scope]
		for key, row := range rows {
			if cutoff > 0 && row.LastSeen < cutoff {
				delete(rows, key)
				s.dirty = true
			}
		}
		if s.maxRecords <= 0 || len(rows) <= s.maxRecords {
			continue
		}
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			a, b := rows[keys[i]], rows[keys[j]]
			if a.LastSeen != b.LastSeen {
				return a.LastSeen < b.LastSeen
			}
			return keys[i] < keys[j]
		})
		for _, key := range keys[:len(rows)-s.maxRecords] {
			delete(rows, key)
		}
		s.dirty = true
	}
}

// Clear удаляет все записи.
func (s *FingerprintStore) Clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, scope := range FingerprintScopes {
		s.scopes[scope] = make(map[string]*storedFingerprint)
	}
	s.since, s.until = 0, 0
	s.dirty = true
}

// Counts — записей по группам.
func (s *FingerprintStore) Counts() map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]int, len(FingerprintScopes))
	for _, scope := range FingerprintScopes {
		out[scope] = len(s.scopes[scope])
	}
	return out
}

func (s *FingerprintStore) Observed() (since, until int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.since, s.until
}

// Rows — копия строк группы в произвольном порядке.
func (s *FingerprintStore) Rows(scope string) []FingerprintRow {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := s.scopes[scope]
	out := make([]FingerprintRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, row.FingerprintRow)
	}
	return out
}

// FingerprintQuery — фильтр, сортировка и страница для списка строк.
type FingerprintQuery struct {
	Sort       string
	Desc       bool
	Search     string
	Suspicious bool
	Offset     int
	Limit      int
}

var fingerprintSortKeys = map[string]bool{
	"key": true, "total": true, "auth_success": true, "bad_or_probe": true,
	"first_seen": true, "last_seen": true, "country": true,
}

func IsFingerprintSort(key string) bool { return fingerprintSortKeys[key] }

// QueryFingerprints применяет запрос к строкам: возвращает страницу и число
// подходящих строк.
func QueryFingerprints(rows []FingerprintRow, q FingerprintQuery) ([]FingerprintRow, int) {
	search := strings.ToLower(strings.TrimSpace(q.Search))
	filtered := make([]FingerprintRow, 0, len(rows))
	for _, r := range rows {
		if q.Suspicious && r.BadOrProbe == 0 {
			continue
		}
		if search != "" && !fingerprintMatches(r, search) {
			continue
		}
		filtered = append(filtered, r)
	}
	less := fingerprintLess(q.Sort)
	sort.SliceStable(filtered, func(i, j int) bool {
		c := less(filtered[i], filtered[j])
		if q.Desc {
			c = -c
		}
		if c != 0 {
			return c < 0
		}
		return filtered[i].Key < filtered[j].Key
	})
	total := len(filtered)
	if q.Offset > total {
		q.Offset = total
	}
	end := total
	if q.Limit > 0 && q.Offset+q.Limit < end {
		end = q.Offset + q.Limit
	}
	return filtered[q.Offset:end], total
}

func fingerprintMatches(r FingerprintRow, search string) bool {
	for _, field := range []string{r.Key, r.JA3, r.JA4, r.Country, r.CountryName, r.City, r.ASNOrg} {
		if strings.Contains(strings.ToLower(field), search) {
			return true
		}
	}
	return false
}

func cmpU(a, b uint64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func cmpI(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func fingerprintLess(key string) func(a, b FingerprintRow) int {
	switch key {
	case "key":
		return func(a, b FingerprintRow) int { return strings.Compare(a.Key, b.Key) }
	case "auth_success":
		return func(a, b FingerprintRow) int { return cmpU(a.AuthSuccess, b.AuthSuccess) }
	case "bad_or_probe":
		return func(a, b FingerprintRow) int { return cmpU(a.BadOrProbe, b.BadOrProbe) }
	case "first_seen":
		return func(a, b FingerprintRow) int { return cmpI(a.FirstSeen, b.FirstSeen) }
	case "last_seen":
		return func(a, b FingerprintRow) int { return cmpI(a.LastSeen, b.LastSeen) }
	case "country":
		return func(a, b FingerprintRow) int { return strings.Compare(a.CountryName, b.CountryName) }
	}
	return func(a, b FingerprintRow) int { return cmpU(a.Total, b.Total) }
}

// LiveFingerprintRows переводит снимок движка в строки панели (когда
// хранилище выключено).
func LiveFingerprintRows(e *EngineFingerprints, scope string) []FingerprintRow {
	src := e.rows(scope)
	out := make([]FingerprintRow, 0, len(src))
	for _, r := range src {
		key := r.Scope
		if scope == "by_fingerprint" || key == "" {
			key = r.JA4
		}
		out = append(out, FingerprintRow{Key: key, JA3: r.JA3, JA3Raw: r.JA3Raw, JA4: r.JA4, JA4Raw: r.JA4Raw,
			Total: r.Total, AuthSuccess: r.AuthSuccess, BadOrProbe: r.BadOrProbe, FirstSeen: r.FirstSeen, LastSeen: r.LastSeen})
	}
	return out
}
