package server

import (
	"errors"
	"net/http/httptest"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/panel_updater"
)

func TestPanelVersionCache(t *testing.T) {
	for _, failed := range []bool{false, true} {
		calls := 0
		handler := panelVersionCheck(func() (*panel_updater.CheckResult, error) {
			calls++
			if failed {
				return nil, errors.New("upstream unavailable")
			}
			return &panel_updater.CheckResult{CurrentVersion: "1.3.14", LatestVersion: "1.3.14"}, nil
		})
		for i := 0; i < 3; i++ {
			rec := httptest.NewRecorder()
			handler(rec, httptest.NewRequest("GET", "/", nil))
			want := 200
			if failed {
				want = 502
			}
			if rec.Code != want {
				t.Fatalf("status %d != %d", rec.Code, want)
			}
		}
		if calls != 1 {
			t.Fatalf("GitHub called %d times", calls)
		}
	}
}
