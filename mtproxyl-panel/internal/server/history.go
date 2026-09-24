package server

import (
	"net/http"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/history"
)

type historyResponse struct {
	Range         string           `json:"range"`
	RequestedFrom int64            `json:"requested_from_epoch_secs"`
	RetentionSecs int64            `json:"retention_secs"`
	Series        []history.Series `json:"series"`
}

// registerHistoryRoutes: GET /api/history?metric=a,b&range=30m.
// rec == nil — история выключена в конфиге.
func (s *Server) registerHistoryRoutes(mux *http.ServeMux, jwtSecret []byte, rec *history.Recorder) {
	mux.Handle("GET /api/history", auth.RequireAuth(jwtSecret, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rec == nil {
			writeError(w, http.StatusServiceUnavailable, "history_disabled", "История метрик выключена в конфиге панели ([history] enabled = false)")
			return
		}
		rng := r.URL.Query().Get("range")
		if rng == "" {
			rng = "30m"
		}
		var metrics []string
		for _, m := range strings.Split(r.URL.Query().Get("metric"), ",") {
			if m = strings.TrimSpace(m); m != "" {
				metrics = append(metrics, m)
			}
		}
		if len(metrics) == 0 {
			writeError(w, http.StatusBadRequest, "bad_request", "Укажите metric")
			return
		}
		now := time.Now()
		resp := historyResponse{Range: rng, Series: make([]history.Series, 0, len(metrics))}
		for _, m := range metrics {
			series, err := rec.Series(m, rng, now)
			if err != nil {
				writeError(w, http.StatusBadRequest, "bad_request", err.Error())
				return
			}
			resp.RequestedFrom = series.RequestedFrom
			resp.RetentionSecs = series.RetentionSecs
			resp.Series = append(resp.Series, series)
		}
		writeJSON(w, http.StatusOK, jsonResponse{OK: true, Data: resp})
	})))
}
