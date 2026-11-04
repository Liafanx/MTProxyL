package server

import (
	"net/http"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/panel_updater"
)

// Все открытые панели делят одну проверку GitHub, включая ошибку лимита запросов.
func panelVersionCheck(check func() (*panel_updater.CheckResult, error)) http.HandlerFunc {
	var mu sync.Mutex
	var at time.Time
	var info *panel_updater.CheckResult
	var lastErr error
	return func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		ttl := 5 * time.Minute
		if lastErr != nil {
			ttl = time.Minute
		}
		if at.IsZero() || time.Since(at) >= ttl {
			info, lastErr = check()
			at = time.Now()
		}
		result, err := info, lastErr
		mu.Unlock()
		w.Header().Set("Cache-Control", "no-store")
		if err != nil {
			writeError(w, 502, "update_check_failed", err.Error())
			return
		}
		writeJSON(w, 200, jsonResponse{OK: true, Data: result})
	}
}
