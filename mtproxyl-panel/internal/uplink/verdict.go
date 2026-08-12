package uplink

import (
	"fmt"
	"time"
)

// Level — светофор блока связи, теми же тремя цветами, что и вердикт
// доступности, чтобы в сообщении они читались одинаково.
type Level string

const (
	LevelGreen  Level = "green"
	LevelYellow Level = "yellow"
	LevelRed    Level = "red"
)

// DefaultFailRateThreshold — доля неудачных подключений за интервал, выше
// которой поднимается тревога. 20% выбрано с большим запасом: на живом сервере
// за всё время работы бывает 47 неудач на 123 488 попыток, то есть 0,04%.
const DefaultFailRateThreshold = 20

// Status — вердикт об исходящей связи и о самом движке.
type Status struct {
	CheckedAt time.Time

	// ── Движок ───────────────────────────────────────────────────────────
	EngineUp       bool
	EngineReadOnly bool
	// EngineError непусто, когда движок не ответил: тогда о связи с DC судить
	// нечего, и прошлый вердикт по ней остаётся в силе.
	EngineError   string
	Version       string
	UptimeSeconds int64
	// Restarted — движок перезапустился с прошлого опроса.
	Restarted bool

	// ── Связь с дата-центрами ────────────────────────────────────────────
	// Applicable=false — middle proxy не используется, судить не о чем.
	// Это не авария: так работает часть установок.
	Applicable          bool
	NotApplicableReason string

	AliveWriters    int
	RequiredWriters int
	DCs             []DCRtt

	// HasFailRate=false — дельту считать было не с чем: первый опрос либо
	// движок перезапустился и обнулил счётчики.
	HasFailRate bool
	Attempts    uint64
	Fails       uint64
	FailRate    float64

	// ── Итог ─────────────────────────────────────────────────────────────
	Level Level
	// Problems — человеческие формулировки сработавших условий, в том же
	// порядке, в каком они проверяются.
	Problems []string
}

// Bad сообщает, надо ли считать состояние связи аварией.
func (s *Status) Bad() bool { return len(s.Problems) > 0 }

// EngineBad — авария самого движка. Отдельно от Bad: это разные инциденты, и
// смешивать их нельзя, иначе одно падение движка приходит двумя сообщениями.
func (s *Status) EngineBad() bool { return !s.EngineUp || s.EngineReadOnly }

// evaluate заполняет Level и Problems.
//
// Условия намеренно только суммарные, по всему пулу писателей. Проверять их по
// каждому DC отдельно нельзя: на живом сервере coverage_pct у DC штатно скачет
// от 0 до 100, а у медиа-DC писателей часто нет вовсе — и при этом всё
// работает. Поэлементная проверка дала бы тревогу круглосуточно, а бота,
// который кричит постоянно, выключают вместе с настоящими тревогами.
//
// Если когда-нибудь захочется «уточнить» это до проверки по каждому DC —
// сначала посмотрите на реальные dc_rtt работающего сервера.
func (s *Status) evaluate(threshold float64) {
	s.Problems = nil

	if !s.Applicable {
		// Судить не о чем — это не зелёный и не красный, но в светофоре
		// нейтрального цвета нет, а тревоги здесь точно нет.
		s.Level = LevelGreen
		return
	}

	switch {
	case s.AliveWriters == 0:
		s.Problems = append(s.Problems,
			"нет ни одного живого писателя — прокси не может писать в Telegram")
	case s.AliveWriters < s.RequiredWriters:
		s.Problems = append(s.Problems, fmt.Sprintf(
			"писателей меньше, чем нужно: %d из %d", s.AliveWriters, s.RequiredWriters))
	}

	// Долю ошибок смотрим, только когда за интервал реально были попытки:
	// «0 неудач из 0 попыток» — это тишина на прокси, а не авария.
	if s.HasFailRate && s.Attempts > 0 && s.FailRate*100 > threshold {
		s.Problems = append(s.Problems, fmt.Sprintf(
			"неудачных подключений %.0f%% за интервал (порог %.0f%%)", s.FailRate*100, threshold))
	}

	switch {
	case s.AliveWriters == 0:
		s.Level = LevelRed
	case len(s.Problems) > 0:
		s.Level = LevelYellow
	default:
		s.Level = LevelGreen
	}
}

// sumWriters складывает писателей по всем дата-центрам.
//
// Суммы совпадают с тем, что панель показывает в сводке «Писатели ME»: на
// живом сервере сумма alive_writers по dc_rtt дала ровно 65 при 43 нужных —
// те же числа, что в отдельном эндпоинте /v1/stats/me-writers. Поэтому за
// агрегатом отдельно ходить не надо.
func sumWriters(dcs []DCRtt) (alive, required int) {
	for _, dc := range dcs {
		alive += dc.AliveWriters
		required += dc.RequiredWriters
	}
	return alive, required
}
