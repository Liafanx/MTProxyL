package tgbot

import (
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

// alertRepeat — как часто напоминать о продолжающейся аварии. Реже, чем идут
// проверки: иначе при затяжном бане чат превращается в будильник каждые 15
// минут, и алерт перестают замечать.
const alertRepeat = 30 * time.Minute

// DefaultThreshold — порог, ниже которого доступность считается аварией.
// 60% выбрано не случайно: при частичном бане адреса отваливается заметная
// часть операторов, а естественный разброс зондов столько не даёт.
const DefaultThreshold = 60

// Event — что случилось с доступностью между двумя вердиктами.
type Event int

const (
	// EventNone — ничего, требующего звука: обычная тихая правка сообщения.
	EventNone Event = iota
	// EventDown — доступность ушла ниже порога либо авария длится и пора
	// напомнить.
	EventDown
	// EventRecovered — вернулись выше порога.
	EventRecovered
)

// AlertState переживает перезапуск панели: иначе после каждого рестарта
// посреди аварии прилетал бы новый алерт, а счётчик длительности начинался бы
// заново.
type AlertState struct {
	Active     bool
	Since      time.Time
	LastNotify time.Time
	LastPct    float64
	// HasPct отличает «раньше было 0%» от «раньше ничего не было»: без него
	// первый же вердикт рисовал бы «Было 0% → стало 95%».
	HasPct bool
}

// Decision — что делать с новым вердиктом и что запомнить.
type Decision struct {
	Event Event
	// Prev и PrevKnown — доступность до этого вердикта, для строки «было → стало».
	Prev      float64
	PrevKnown bool
	// AlertSince — начало текущей аварии, для «длится N». При восстановлении
	// это начало только что закончившейся аварии.
	AlertSince time.Time
	// State — то, что нужно сохранить на диск.
	State AlertState
}

// Decide решает судьбу нового вердикта.
//
// Отдельно оговорено: сорвавшаяся проверка (Error или ноль зондов) не событие
// и не нулевая доступность. Измерения не было — значит и вывода о прокси нет,
// а уже объявленная авария от этого не «вылечилась».
func Decide(st AlertState, r *globalping.CheckResult, threshold float64, now time.Time) Decision {
	d := Decision{
		Event:      EventNone,
		Prev:       st.LastPct,
		PrevKnown:  st.HasPct,
		AlertSince: st.Since,
		State:      st,
	}

	if r == nil || r.Error != "" || r.TotalProbes == 0 {
		return d
	}

	if threshold <= 0 {
		threshold = DefaultThreshold
	}

	d.State.LastPct = r.Percentage
	d.State.HasPct = true

	// Сам автомат общий для всех аварий — доступности, связи с дата-центрами и
	// движка (см. decideIncident в incidents.go). Здесь остаётся только то, что
	// свойственно именно доступности: проценты и порог.
	incident, event, since := decideIncident(st.incident(), r.Percentage < threshold, now)
	d.State.setIncident(incident)
	d.Event = event
	d.AlertSince = since
	return d
}

// incident/setIncident связывают состояние доступности с общим автоматом:
// у него те же три поля плюс проценты, которые автомату не нужны.
func (a AlertState) incident() IncidentState {
	return IncidentState{Active: a.Active, Since: a.Since, LastNotify: a.LastNotify}
}

func (a *AlertState) setIncident(i IncidentState) {
	a.Active, a.Since, a.LastNotify = i.Active, i.Since, i.LastNotify
}
