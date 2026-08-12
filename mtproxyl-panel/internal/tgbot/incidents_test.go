package tgbot

import (
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/uplink"
)

func healthyUplink() *uplink.Status {
	return &uplink.Status{
		EngineUp:        true,
		Applicable:      true,
		AliveWriters:    65,
		RequiredWriters: 43,
		Level:           uplink.LevelGreen,
	}
}

func brokenUplink() *uplink.Status {
	st := healthyUplink()
	st.AliveWriters = 0
	st.Level = uplink.LevelRed
	st.Problems = []string{"нет ни одного живого писателя"}
	return st
}

func TestUplinkIncidentRaisesAndClears(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	var in Incidents

	d := DecideUplink(in, brokenUplink(), now)
	if d.UplinkEvent != EventDown {
		t.Fatalf("UplinkEvent = %v, ожидалось EventDown", d.UplinkEvent)
	}
	if !d.State.Uplink.Active {
		t.Error("авария связи не отмечена активной")
	}

	// Пока не прошло получаса — молчим, хотя авария длится.
	in = d.State
	if d2 := DecideUplink(in, brokenUplink(), now.Add(10*time.Minute)); d2.UplinkEvent != EventNone {
		t.Errorf("UplinkEvent = %v через 10 минут, ожидалось молчание", d2.UplinkEvent)
	}

	// Через получас — напоминание.
	if d3 := DecideUplink(in, brokenUplink(), now.Add(31*time.Minute)); d3.UplinkEvent != EventDown {
		t.Errorf("UplinkEvent = %v через 31 минуту, ожидалось напоминание", d3.UplinkEvent)
	}

	// Восстановление отдаёт начало аварии, чтобы сказать, сколько она длилась.
	d4 := DecideUplink(in, healthyUplink(), now.Add(40*time.Minute))
	if d4.UplinkEvent != EventRecovered {
		t.Fatalf("UplinkEvent = %v, ожидалось EventRecovered", d4.UplinkEvent)
	}
	if !d4.UplinkSince.Equal(now) {
		t.Errorf("UplinkSince = %v, ожидалось начало аварии %v", d4.UplinkSince, now)
	}
	if d4.State.Uplink.Active {
		t.Error("авария связи осталась активной после восстановления")
	}
}

// Движок не ответил — состояние связи не трогается вовсе. Иначе одно падение
// движка пришло бы двумя тревогами про одно и то же.
func TestEngineErrorLeavesUplinkIncidentUntouched(t *testing.T) {
	now := time.Now()
	in := Incidents{Uplink: IncidentState{Active: true, Since: now.Add(-time.Hour), LastNotify: now}}

	// FailedPolls выше порога: одиночный сбой опроса тревогой не считается,
	// движок перезапускается за секунды.
	st := &uplink.Status{EngineError: "движок telemt не отвечает", FailedPolls: 3}
	d := DecideUplink(in, st, now)

	if d.UplinkEvent != EventNone {
		t.Errorf("UplinkEvent = %v при недоступном движке, ожидалось молчание", d.UplinkEvent)
	}
	if !d.State.Uplink.Active {
		t.Error("авария связи снята из-за недоступности движка")
	}
	if d.EngineEvent != EventDown {
		t.Errorf("EngineEvent = %v, ожидалась тревога о движке", d.EngineEvent)
	}
}

// Выключенный middle proxy гасит аварию связи молча: оператор сам его
// выключил, и «связь восстановлена» было бы неправдой.
func TestDisabledMiddleProxyClearsUplinkSilently(t *testing.T) {
	now := time.Now()
	in := Incidents{Uplink: IncidentState{Active: true, Since: now.Add(-time.Hour), LastNotify: now}}

	st := &uplink.Status{EngineUp: true, Applicable: false, NotApplicableReason: "выключен"}
	d := DecideUplink(in, st, now)

	if d.UplinkEvent != EventNone {
		t.Errorf("UplinkEvent = %v, ожидалось молчание", d.UplinkEvent)
	}
	if d.State.Uplink.Active {
		t.Error("авария связи осталась активной при выключенном middle proxy")
	}
}

func TestEngineRestartIsReported(t *testing.T) {
	st := healthyUplink()
	st.Restarted = true

	if d := DecideUplink(Incidents{}, st, time.Now()); !d.Restarted {
		t.Error("перезапуск движка не отмечен")
	}
}

func TestEngineReadOnlyRaisesIncident(t *testing.T) {
	st := healthyUplink()
	st.EngineReadOnly = true

	if d := DecideUplink(Incidents{}, st, time.Now()); d.EngineEvent != EventDown {
		t.Errorf("EngineEvent = %v при режиме только чтения, ожидалась тревога", d.EngineEvent)
	}
}

// Доступность и связь независимы — в этом и смысл двух источников.
func TestAvailabilityAndUplinkAreIndependent(t *testing.T) {
	now := time.Now()
	in := Incidents{Availability: AlertState{Active: true, Since: now, LastNotify: now, LastPct: 20, HasPct: true}}

	d := DecideUplink(in, healthyUplink(), now)

	if !d.State.Availability.Active {
		t.Error("исправная связь погасила аварию доступности")
	}
	if d.State.Uplink.Active {
		t.Error("авария доступности зажгла аварию связи")
	}
}

// ── Смена внешнего адреса ───────────────────────────────────────────────────

func TestIPChangeNeedsTwoFreshObservations(t *testing.T) {
	known, pending := "203.0.113.10", ""

	known, pending, changed := DecideIPChange(known, pending, "198.51.100.7", true)
	if changed {
		t.Error("смена адреса объявлена по одному наблюдению")
	}
	if known != "203.0.113.10" {
		t.Errorf("known = %q, адрес не должен был смениться", known)
	}

	known, pending, changed = DecideIPChange(known, pending, "198.51.100.7", true)
	if !changed {
		t.Fatal("смена адреса не объявлена после подтверждения")
	}
	if known != "198.51.100.7" {
		t.Errorf("known = %q", known)
	}
	if pending != "" {
		t.Errorf("pending = %q, ожидалось пусто", pending)
	}
}

// Резолвер намеренно отдаёт последний известный адрес, когда сервисы не
// ответили. Считать это сменой нельзя.
func TestStaleIPIsNotAChange(t *testing.T) {
	known, pending, changed := DecideIPChange("203.0.113.10", "", "198.51.100.7", false)
	if changed || known != "203.0.113.10" || pending != "" {
		t.Errorf("несвежий ответ принят за смену: known=%q pending=%q changed=%v", known, pending, changed)
	}
}

func TestFirstIPObservationIsNotAChange(t *testing.T) {
	known, _, changed := DecideIPChange("", "", "203.0.113.10", true)
	if changed {
		t.Error("первое наблюдение адреса объявлено сменой")
	}
	if known != "203.0.113.10" {
		t.Errorf("known = %q, адрес не запомнен", known)
	}
}

// Разовый сбой сервиса, отдавшего чужой адрес, не должен пройти: следующее
// наблюдение вернёт прежний адрес и отменит ожидание.
func TestSingleWrongIPIsForgotten(t *testing.T) {
	known, pending := "203.0.113.10", ""

	known, pending, _ = DecideIPChange(known, pending, "198.51.100.7", true)
	known, pending, changed := DecideIPChange(known, pending, "203.0.113.10", true)

	if changed {
		t.Error("возврат к прежнему адресу объявлен сменой")
	}
	if known != "203.0.113.10" || pending != "" {
		t.Errorf("known=%q pending=%q, ожидалось сохранение прежнего адреса", known, pending)
	}
}

// ── Пауза тревог ────────────────────────────────────────────────────────────

func TestMuteWindow(t *testing.T) {
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)

	if (Incidents{}).Muted(now) {
		t.Error("тревоги заглушены без паузы")
	}
	if !(Incidents{MutedUntil: now.Add(time.Hour)}).Muted(now) {
		t.Error("пауза не действует внутри окна")
	}
	if (Incidents{MutedUntil: now.Add(-time.Minute)}).Muted(now) {
		t.Error("истёкшая пауза продолжает действовать")
	}
	if !(Incidents{MuteForever: true}).Muted(now) {
		t.Error("пауза до отмены не действует")
	}
}

func TestAnyActiveSeesEveryIncident(t *testing.T) {
	if (Incidents{}).AnyActive() {
		t.Error("аварий нет, а AnyActive = true")
	}
	if !(Incidents{Availability: AlertState{Active: true}}).AnyActive() {
		t.Error("не замечена авария доступности")
	}
	if !(Incidents{Uplink: IncidentState{Active: true}}).AnyActive() {
		t.Error("не замечена авария связи")
	}
	if !(Incidents{Engine: IncidentState{Active: true}}).AnyActive() {
		t.Error("не замечена авария движка")
	}
}

// Одиночный сбой опроса — не тревога. Иначе каждый перезапуск движка
// (обновление, смена настроек) приходил бы парой «упал» — «вернулся».
func TestSingleFailedPollIsNotAnEngineIncident(t *testing.T) {
	st := &uplink.Status{EngineError: "движок telemt не отвечает", FailedPolls: 1}

	if d := DecideUplink(Incidents{}, st, time.Now()); d.EngineEvent != EventNone {
		t.Errorf("EngineEvent = %v при одиночном сбое, ожидалось молчание", d.EngineEvent)
	}
}
