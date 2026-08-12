package uplink

import (
	"context"
	"net/http"
	"testing"
)

// Проверка обратной стороны замены критерия: настоящая поломка выхода всё ещё
// ловится. Отказы без повтора появляются — тревога должна прийти.
func TestHardFailuresStillRaiseAlarm(t *testing.T) {
	attempts, fails, hard := uint64(1000), uint64(100), uint64(0)
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		switch path {
		case "/v1/runtime/me_quality":
			ok(w, productionDCs)
		case "/v1/runtime/upstream_quality":
			ok(w, `{"enabled":true,"counters":{"connect_attempt_total":`+utoa(attempts)+
				`,"connect_fail_total":`+utoa(fails)+
				`,"connect_failfast_hard_error_total":`+utoa(hard)+`}}`)
		}
	})
	w := newTestWatcher(c)
	w.Poll(context.Background()) // база

	for i := 0; i < 3; i++ {
		attempts += 100
		fails += 90
		hard += 90 // движок даже не пытается повторить
		w.Poll(context.Background())
	}
	if st := w.Snapshot(); !st.Bad() {
		t.Fatalf("настоящая поломка выхода не поднимает тревогу: hard=%d/%d", st.HardFails, st.Attempts)
	}
}

// И вторая страховка: если связь действительно пропала, писатели умирают —
// это ловится мгновенно, независимо от счётчиков подключений.
func TestDeadPoolStillAlarmsInstantly(t *testing.T) {
	c := fakeTelemt(t, func(path string, w http.ResponseWriter) {
		if healthyEngine(path, w) {
			return
		}
		if path == "/v1/runtime/me_quality" {
			ok(w, `{"enabled":true,"data":{"dc_rtt":[
			 {"dc":1,"rtt_ema_ms":null,"alive_writers":0,"required_writers":3,"coverage_pct":0}]}}`)
		}
	})

	if st := newTestWatcher(c).Poll(context.Background()); !st.Bad() || st.Level != LevelRed {
		t.Fatalf("мёртвый пул не даёт мгновенной тревоги: Bad=%v Level=%s", st.Bad(), st.Level)
	}
}
