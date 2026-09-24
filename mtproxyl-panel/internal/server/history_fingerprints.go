package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/geoip"
	"github.com/Liafanx/mtproxyl-panel/internal/history"
)

type fingerprintsResponse struct {
	Scope      string                   `json:"scope"`
	Source     string                   `json:"source"`
	Sort       string                   `json:"sort"`
	Order      string                   `json:"order"`
	Offset     int                      `json:"offset"`
	Limit      int                      `json:"limit"`
	Total      int                      `json:"total"`
	Counts     map[string]int           `json:"counts"`
	Suspicious map[string]int           `json:"suspicious"`
	Rows       []history.FingerprintRow `json:"rows"`
	Gate       fingerprintsGateInfo     `json:"gate"`
	Engine     history.EngineMeta       `json:"engine"`
	GeoIP      bool                     `json:"geoip"`
	Since      int64                    `json:"observed_since_epoch_secs,omitempty"`
	Until      int64                    `json:"observed_until_epoch_secs,omitempty"`
}

type fingerprintsGateInfo struct {
	Seen    bool   `json:"seen"`
	Enabled bool   `json:"enabled"`
	Reason  string `json:"reason,omitempty"`
}

type storageResponse struct {
	Traffic      storageTraffic      `json:"traffic"`
	Fingerprints storageFingerprints `json:"fingerprints"`
	Memory       storageMemory       `json:"memory"`
	Limits       history.Limits      `json:"limits"`
	DataDir      string              `json:"data_dir"`
}

type storageTraffic struct {
	Enabled bool   `json:"enabled"`
	Path    string `json:"path,omitempty"`
	Bytes   int64  `json:"bytes"`
	Users   int    `json:"users"`
	Since   int64  `json:"observed_since_epoch_secs,omitempty"`
	Until   int64  `json:"observed_until_epoch_secs,omitempty"`
}

type storageFingerprints struct {
	Enabled bool           `json:"enabled"`
	Path    string         `json:"path,omitempty"`
	Bytes   int64          `json:"bytes"`
	Counts  map[string]int `json:"counts"`
	Records int            `json:"records"`
	Since   int64          `json:"observed_since_epoch_secs,omitempty"`
	Until   int64          `json:"observed_until_epoch_secs,omitempty"`
}

type storageMemory struct {
	Points        int   `json:"points"`
	Bytes         int64 `json:"bytes"`
	RetentionSecs int64 `json:"retention_secs"`
}

// fingerprintFetcher — живой запрос к движку, когда хранилище панели выключено.
type fingerprintFetcher interface {
	GetJSON(ctx context.Context, path string, out any) error
}

func parseFingerprintQuery(r *http.Request) (history.FingerprintQuery, string, error) {
	q := r.URL.Query()
	fq := history.FingerprintQuery{Sort: q.Get("sort"), Search: q.Get("q"), Limit: 50}
	if fq.Sort == "" {
		fq.Sort = "total"
	}
	if !history.IsFingerprintSort(fq.Sort) {
		return fq, "", errors.New("Неизвестная сортировка: " + fq.Sort)
	}
	order := q.Get("order")
	if order == "" {
		order = "desc"
	}
	if order != "asc" && order != "desc" {
		return fq, "", errors.New("order: asc или desc")
	}
	fq.Desc = order == "desc"
	fq.Suspicious = q.Get("suspicious") == "1" || q.Get("suspicious") == "true"
	if v := q.Get("offset"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			return fq, "", errors.New("offset: неотрицательное число")
		}
		fq.Offset = n
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 1000 {
			return fq, "", errors.New("limit: 1..1000")
		}
		fq.Limit = n
	}
	return fq, order, nil
}

// enrichGeo подставляет страну и провайдера для IP и подсетей.
func enrichGeo(lookup *geoip.Lookup, scope string, rows []history.FingerprintRow) bool {
	if lookup == nil || (scope != "by_ip" && scope != "by_cidr") {
		return lookup != nil
	}
	ips := make([]string, len(rows))
	for i, r := range rows {
		ips[i] = strings.SplitN(r.Key, "/", 2)[0]
	}
	for i, info := range lookup.LookupIPs(ips) {
		if info.Country == "??" {
			continue
		}
		rows[i].Country, rows[i].CountryName, rows[i].City, rows[i].ASNOrg = info.Country, info.CountryName, info.City, info.ASNOrg
	}
	return true
}

func suspiciousCounts(rowsOf func(scope string) []history.FingerprintRow) (counts, suspicious map[string]int) {
	counts = make(map[string]int, len(history.FingerprintScopes))
	suspicious = make(map[string]int, len(history.FingerprintScopes))
	for _, scope := range history.FingerprintScopes {
		rows := rowsOf(scope)
		counts[scope] = len(rows)
		for _, r := range rows {
			if r.BadOrProbe > 0 {
				suspicious[scope]++
			}
		}
	}
	return counts, suspicious
}

// registerFingerprintRoutes: GET /api/history/fingerprints, GET/PUT
// /api/history/storage, DELETE /api/history/traffic и /api/history/fingerprints.
func (s *Server) registerFingerprintRoutes(mux *http.ServeMux, jwtSecret []byte, rec *history.Recorder, live fingerprintFetcher) {
	var store *history.FingerprintStore
	if rec != nil {
		store = rec.Fingerprints()
	}

	mux.Handle("GET /api/history/fingerprints", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scope := r.URL.Query().Get("scope")
		if scope == "" {
			scope = "by_fingerprint"
		}
		if !history.IsFingerprintScope(scope) {
			writeError(w, http.StatusBadRequest, "bad_request", "Неизвестная группа: "+scope)
			return
		}
		fq, order, err := parseFingerprintQuery(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}
		lookup := getGeoIPLookup(s.cfg)
		resp := fingerprintsResponse{Scope: scope, Sort: fq.Sort, Order: order, Offset: fq.Offset, Limit: fq.Limit}

		var rowsOf func(scope string) []history.FingerprintRow
		if store != nil {
			resp.Source = "panel"
			rowsOf = store.Rows
			seen, enabled, reason := store.Gate()
			resp.Gate = fingerprintsGateInfo{Seen: seen, Enabled: enabled, Reason: reason}
			resp.Engine = store.Engine()
			resp.Since, resp.Until = store.Observed()
		} else {
			resp.Source = "engine"
			var gate struct {
				Enabled bool                        `json:"enabled"`
				Reason  string                      `json:"reason"`
				Data    *history.EngineFingerprints `json:"data"`
			}
			if err := live.GetJSON(r.Context(), "/v1/runtime/tls-fingerprints?limit="+strconv.Itoa(history.FingerprintPollLimit), &gate); err != nil {
				writeError(w, http.StatusBadGateway, "telemt_unreachable", err.Error())
				return
			}
			resp.Gate = fingerprintsGateInfo{Seen: true, Enabled: gate.Enabled && gate.Data != nil, Reason: gate.Reason}
			data := gate.Data
			if data == nil {
				data = &history.EngineFingerprints{}
			} else {
				resp.Engine = history.EngineMeta{Limit: data.Limit, RetentionSecs: data.RetentionSecs, Capacity: data.Capacity, DroppedTotal: data.DroppedTotal, ParseErrorTotal: data.ParseErrorTotal, FetchedAt: time.Now().Unix()}
			}
			rowsOf = func(sc string) []history.FingerprintRow { return history.LiveFingerprintRows(data, sc) }
		}
		resp.Counts, resp.Suspicious = suspiciousCounts(rowsOf)
		rows := rowsOf(scope)
		resp.GeoIP = enrichGeo(lookup, scope, rows)
		resp.Rows, resp.Total = history.QueryFingerprints(rows, fq)
		if resp.Rows == nil {
			resp.Rows = []history.FingerprintRow{}
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: resp})
	})))

	storage := func() storageResponse {
		resp := storageResponse{DataDir: s.cfg.DataDir, Limits: history.DefaultLimits()}
		if rec == nil {
			return resp
		}
		resp.Limits = rec.Limits()
		series, points := rec.Ring().Size()
		resp.Memory = storageMemory{Points: points, Bytes: int64(points)*16 + int64(series)*64, RetentionSecs: int64(rec.Ring().Retention() / time.Second)}
		if t := rec.Traffic(); t != nil {
			since, until := t.Observed()
			resp.Traffic = storageTraffic{Enabled: true, Path: t.Path(), Bytes: history.FileSize(t.Path()), Users: t.UsersCount(), Since: since, Until: until}
		}
		if f := rec.Fingerprints(); f != nil {
			since, until := f.Observed()
			counts := f.Counts()
			total := 0
			for _, n := range counts {
				total += n
			}
			resp.Fingerprints = storageFingerprints{Enabled: true, Path: f.Path(), Bytes: history.FileSize(f.Path()), Counts: counts, Records: total, Since: since, Until: until}
		}
		return resp
	}

	mux.Handle("GET /api/history/storage", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: storage()})
	})))

	mux.Handle("PUT /api/history/limits", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rec == nil {
			writeError(w, http.StatusServiceUnavailable, "history_disabled", "История выключена в конфиге панели ([history] enabled = false)")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		var l history.Limits
		if err := json.NewDecoder(r.Body).Decode(&l); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "Некорректное тело запроса")
			return
		}
		if err := l.Validate(); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}
		if err := rec.SetLimits(l); err != nil {
			writeError(w, http.StatusInternalServerError, "save_failed", err.Error())
			return
		}
		rec.Save()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: storage()})
	})))

	clearStore := func(w http.ResponseWriter, what string, fn func() bool) {
		if rec == nil || !fn() {
			writeError(w, http.StatusServiceUnavailable, "history_disabled", what+" выключена: нет data_dir или [history] enabled = false")
			return
		}
		rec.Save()
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: storage()})
	}
	mux.Handle("DELETE /api/history/traffic", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clearStore(w, "История трафика", func() bool {
			if rec.Traffic() == nil {
				return false
			}
			rec.Traffic().Clear(r.URL.Query().Get("user"))
			return true
		})
	})))
	mux.Handle("DELETE /api/history/fingerprints", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clearStore(w, "История отпечатков", func() bool {
			if rec.Fingerprints() == nil {
				return false
			}
			rec.Fingerprints().Clear()
			return true
		})
	})))
}
