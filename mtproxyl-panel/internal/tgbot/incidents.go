package tgbot

import (
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/uplink"
)

// IncidentState — состояние одной аварии. Переживает перезапуск панели: иначе
// каждый рестарт посреди аварии присылал бы новую тревогу, а счётчик
// длительности начинался бы заново.
type IncidentState struct {
	Active     bool
	Since      time.Time
	LastNotify time.Time
}

// Incidents — вся память бота о происходящем.
//
// Инциденты независимы: доступность может упасть при живой связи с
// дата-центрами и наоборот — это и есть смысл двух источников наблюдения.
type Incidents struct {
	// Availability хранит ещё и проценты, поэтому у него свой тип.
	Availability AlertState
	Uplink       IncidentState
	Engine       IncidentState

	// LastKnownIP — внешний адрес сервера, каким мы его видели в прошлый раз.
	// Живёт здесь, а не в кэше резолвера: тот держит адрес десять минут и не
	// переживает перезапуск, а помнить вчерашний адрес нужно.
	LastKnownIP string

	// MutedUntil / MuteForever — пауза тревог на время работ.
	MutedUntil  time.Time
	MuteForever bool
}

// Muted сообщает, заглушены ли сейчас звуковые тревоги.
func (i Incidents) Muted(now time.Time) bool {
	return i.MuteForever || (!i.MutedUntil.IsZero() && now.Before(i.MutedUntil))
}

// AnyActive — есть ли сейчас хоть одна незакрытая авария. Нужно при снятии
// паузы: если авария всё ещё идёт, промолчать нельзя.
func (i Incidents) AnyActive() bool {
	return i.Availability.Active || i.Uplink.Active || i.Engine.Active
}

// decideIncident — общий автомат для всех аварий. Ровно та же логика, что
// была написана для доступности, но без предметной специфики: три ветки —
// «стало плохо», «плохо и пора напомнить», «отпустило».
func decideIncident(st IncidentState, bad bool, now time.Time) (IncidentState, Event, time.Time) {
	since := st.Since

	if bad {
		switch {
		case !st.Active:
			// Первое срабатывание. Сюда же попадает самый первый вердикт, если
			// он сразу плохой: систему могли поднять уже сломанной, и молчать
			// об этом вреднее, чем разбудить.
			st.Active, st.Since, st.LastNotify = true, now, now
			return st, EventDown, now
		case now.Sub(st.LastNotify) >= alertRepeat:
			st.LastNotify = now
			return st, EventDown, since
		}
		return st, EventNone, since
	}

	if st.Active {
		st.Active = false
		st.Since = time.Time{}
		st.LastNotify = now
		// Начало отдаём наверх до обнуления: сообщение о восстановлении должно
		// сказать, сколько авария длилась.
		return st, EventRecovered, since
	}
	return st, EventNone, since
}

// UplinkDecision — итог оценки связи с дата-центрами и состояния движка.
type UplinkDecision struct {
	UplinkEvent Event
	UplinkSince time.Time
	EngineEvent Event
	EngineSince time.Time
	// Restarted — движок перезапустился. Одноразовое событие: у него нет
	// «восстановления», о нём просто сообщают один раз.
	Restarted bool
	State     Incidents
}

// DecideUplink оценивает вердикт наблюдателя за исходящей связью.
//
// Два правила, которые нельзя нарушать:
//
// Первое: когда движок не ответил, состояние связи не трогается вовсе — ни
// поднимается, ни гасится. Измерения не было, судить не о чем. Иначе одно
// падение движка приходило бы двумя тревогами про одно и то же.
//
// Второе: выключенный middle proxy гасит аварию связи молча, без сообщения о
// восстановлении. Оператор сам его выключил, и «✅ связь восстановлена» было
// бы неправдой.
func DecideUplink(in Incidents, st *uplink.Status, now time.Time) UplinkDecision {
	d := UplinkDecision{State: in, UplinkSince: in.Uplink.Since, EngineSince: in.Engine.Since}
	if st == nil {
		return d
	}

	d.State.Engine, d.EngineEvent, d.EngineSince = decideIncident(in.Engine, st.EngineBad(), now)
	d.Restarted = st.Restarted

	switch {
	case st.EngineError != "":
		// Данных о связи нет — оставляем как было.
	case !st.Applicable:
		if in.Uplink.Active {
			d.State.Uplink = IncidentState{}
		}
	default:
		d.State.Uplink, d.UplinkEvent, d.UplinkSince = decideIncident(in.Uplink, st.Bad(), now)
	}
	return d
}

// DecideIPChange решает, сообщать ли о смене внешнего адреса сервера.
//
// Адрес приходит от сторонних сервисов, и резолвер намеренно отдаёт последнее
// известное значение, когда они не ответили. Поэтому: несвежий ответ переходом
// не считается; первое в жизни наблюдение — знакомство, а не смена; а новый
// адрес принимается только после двух подряд свежих наблюдений. Последнее —
// от того, что сервисы определения IP изредка отвечают честным успехом с
// другого edge-адреса, и без этого бот сообщал бы о переезде, которого не было.
func DecideIPChange(known, pending, observed string, fresh bool) (newKnown, newPending string, changed bool) {
	if !fresh || observed == "" {
		return known, pending, false
	}
	if known == "" {
		return observed, "", false // знакомство
	}
	if observed == known {
		return known, "", false
	}
	if pending != observed {
		// Первое наблюдение нового адреса — ждём подтверждения следующим.
		return known, observed, false
	}
	return observed, "", true
}
