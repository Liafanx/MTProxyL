package tgbot

import (
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

func verdict(pct float64) *globalping.CheckResult {
	return &globalping.CheckResult{
		Percentage:    pct,
		TotalProbes:   20,
		SuccessProbes: int(pct / 5),
	}
}

func failedVerdict() *globalping.CheckResult {
	return &globalping.CheckResult{Error: "сервис проверки не отвечает", Level: globalping.LevelRed}
}

func TestDecideTransitions(t *testing.T) {
	now := time.Date(2026, 8, 11, 17, 30, 0, 0, time.UTC)

	cases := []struct {
		name       string
		state      AlertState
		result     *globalping.CheckResult
		wantEvent  Event
		wantActive bool
	}{
		{
			name:      "первый вердикт в норме — тишина",
			result:    verdict(95),
			wantEvent: EventNone,
		},
		{
			name:       "первое падение ниже порога — алерт",
			result:     verdict(55),
			wantEvent:  EventDown,
			wantActive: true,
		},
		{
			name:       "авария длится, 30 минут не прошло — молчим",
			state:      AlertState{Active: true, Since: now.Add(-20 * time.Minute), LastNotify: now.Add(-20 * time.Minute), LastPct: 55, HasPct: true},
			result:     verdict(50),
			wantEvent:  EventNone,
			wantActive: true,
		},
		{
			name:       "авария длится больше 30 минут — напоминание",
			state:      AlertState{Active: true, Since: now.Add(-70 * time.Minute), LastNotify: now.Add(-31 * time.Minute), LastPct: 55, HasPct: true},
			result:     verdict(50),
			wantEvent:  EventDown,
			wantActive: true,
		},
		{
			name:       "вернулись выше порога — восстановление",
			state:      AlertState{Active: true, Since: now.Add(-40 * time.Minute), LastNotify: now.Add(-10 * time.Minute), LastPct: 55, HasPct: true},
			result:     verdict(90),
			wantEvent:  EventRecovered,
			wantActive: false,
		},
		{
			name:      "всё хорошо и было хорошо — тишина",
			state:     AlertState{LastPct: 95, HasPct: true},
			result:    verdict(90),
			wantEvent: EventNone,
		},
		{
			name:      "ровно на пороге авариями не считается",
			state:     AlertState{LastPct: 95, HasPct: true},
			result:    verdict(60),
			wantEvent: EventNone,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := Decide(tc.state, tc.result, DefaultThreshold, now)
			if d.Event != tc.wantEvent {
				t.Errorf("Event = %v, want %v", d.Event, tc.wantEvent)
			}
			if d.State.Active != tc.wantActive {
				t.Errorf("State.Active = %v, want %v", d.State.Active, tc.wantActive)
			}
		})
	}
}

// Сорвавшаяся проверка — не нулевая доступность. Ложный алерт про бан здесь
// был бы худшим из возможных: он приучает не верить алертам.
func TestDecideIgnoresFailedCheck(t *testing.T) {
	now := time.Now()
	st := AlertState{LastPct: 95, HasPct: true}

	d := Decide(st, failedVerdict(), DefaultThreshold, now)

	if d.Event != EventNone {
		t.Errorf("Event = %v, ожидалось EventNone", d.Event)
	}
	if d.State != st {
		t.Errorf("состояние изменилось: %+v, было %+v", d.State, st)
	}
}

// Проверка сорвалась посреди аварии — авария не «вылечилась» от того, что
// Globalping не ответил.
func TestDecideFailedCheckDoesNotClearActiveAlert(t *testing.T) {
	now := time.Now()
	st := AlertState{Active: true, Since: now.Add(-time.Hour), LastNotify: now, LastPct: 40, HasPct: true}

	d := Decide(st, failedVerdict(), DefaultThreshold, now)

	if !d.State.Active {
		t.Error("авария снята сорвавшейся проверкой")
	}
	if d.Event != EventNone {
		t.Errorf("Event = %v, ожидалось EventNone", d.Event)
	}
}

// Ноль зондов — то же самое: измерения не было.
func TestDecideIgnoresZeroProbes(t *testing.T) {
	d := Decide(AlertState{}, &globalping.CheckResult{TotalProbes: 0}, DefaultThreshold, time.Now())
	if d.Event != EventNone || d.State.Active {
		t.Errorf("пустое измерение принято за аварию: %+v", d)
	}
}

// Перезапуск панели посреди аварии: состояние прочитано с диска, повторный
// алерт не сыплется, а счётчик длительности продолжается с прежнего начала.
func TestDecideSurvivesRestartMidOutage(t *testing.T) {
	now := time.Date(2026, 8, 11, 18, 0, 0, 0, time.UTC)
	since := now.Add(-2 * time.Hour)
	restored := AlertState{Active: true, Since: since, LastNotify: now.Add(-5 * time.Minute), LastPct: 45, HasPct: true}

	d := Decide(restored, verdict(45), DefaultThreshold, now)

	if d.Event != EventNone {
		t.Errorf("Event = %v: после перезапуска прилетел лишний алерт", d.Event)
	}
	if !d.AlertSince.Equal(since) {
		t.Errorf("AlertSince = %v, ожидалось сохранённое %v", d.AlertSince, since)
	}
}

// При восстановлении сообщение обязано сказать, сколько авария длилась, —
// значит начало нужно отдать наверх до того, как оно забудется.
func TestDecideRecoveryKeepsOutageStartForRendering(t *testing.T) {
	now := time.Date(2026, 8, 11, 18, 0, 0, 0, time.UTC)
	since := now.Add(-90 * time.Minute)
	st := AlertState{Active: true, Since: since, LastNotify: now.Add(-10 * time.Minute), LastPct: 55, HasPct: true}

	d := Decide(st, verdict(90), DefaultThreshold, now)

	if d.Event != EventRecovered {
		t.Fatalf("Event = %v, ожидалось EventRecovered", d.Event)
	}
	if !d.AlertSince.Equal(since) {
		t.Errorf("AlertSince = %v, ожидалось %v", d.AlertSince, since)
	}
	if !d.State.Since.IsZero() {
		t.Errorf("State.Since = %v, после восстановления должно обнулиться", d.State.Since)
	}
}

func TestDecideCarriesPreviousPercentage(t *testing.T) {
	now := time.Now()

	first := Decide(AlertState{}, verdict(95), DefaultThreshold, now)
	if first.PrevKnown {
		t.Error("PrevKnown = true для самого первого вердикта")
	}
	if !first.State.HasPct || first.State.LastPct != 95 {
		t.Errorf("State = %+v, ожидалось запоминание 95%%", first.State)
	}

	second := Decide(first.State, verdict(55), DefaultThreshold, now)
	if !second.PrevKnown || second.Prev != 95 {
		t.Errorf("Prev = %.0f (known=%v), ожидалось 95", second.Prev, second.PrevKnown)
	}
}

// Порог настраивается, и ноль означает «не задан» — тогда берём умолчание.
func TestDecideThresholdIsConfigurable(t *testing.T) {
	now := time.Now()

	if d := Decide(AlertState{}, verdict(75), 80, now); d.Event != EventDown {
		t.Errorf("при пороге 80%% доступность 75%% должна быть аварией, получено %v", d.Event)
	}
	if d := Decide(AlertState{}, verdict(75), 0, now); d.Event != EventNone {
		t.Errorf("при нулевом пороге берётся умолчание %d%%, авария не ожидалась", DefaultThreshold)
	}
}
