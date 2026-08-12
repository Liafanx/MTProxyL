// Package uplink следит за исходящей связью прокси с дата-центрами Telegram.
//
// Проверка «Доступность из России» (internal/globalping) отвечает на вопрос
// «видят ли меня клиенты» — это вход. Но фильтрация у российского хостера
// часто режет не вход, а выход: виртуалка остаётся доступной снаружи, а доступ
// от неё до дата-центров Telegram урезают. Тогда зонды показывают те же 95%,
// а клиенты не работают. Отсюда второй, независимый источник наблюдения.
//
// Данные берутся у самого движка telemt по HTTP. Свой фоновый тикер нужен
// потому, что опрос телеметрии в панели живёт ровно пока открыта вкладка
// браузера (см. internal/ws/handler.go) — для оповещений это не годится.
package uplink

// Ответы telemt приходят в общем конверте {ok, data, error{code,message}}.
// Структуры ниже описывают то, что лежит внутри data, и портированы из
// frontend/src/types/runtime.ts: в Go этих типов до сих пор не было — панель
// декодировала телеметрию в interface{} и пересылала в браузер как есть.

// DCRtt — строка таблицы «Состояние дата-центров».
//
// Клиент Telegram привязан к своему дата-центру, поэтому недоступность одного
// DC задевает только часть пользователей. Но судить по отдельному DC нельзя:
// на живом сервере coverage_pct штатно скачет от 0 до 100, а медиа-DC часто
// вовсе без писателей. Поэтому эти цифры мы показываем, а решение об аварии
// принимаем по сумме — см. verdict.go.
type DCRtt struct {
	DC              int      `json:"dc"`
	RTTEmaMs        *float64 `json:"rtt_ema_ms"`
	AliveWriters    int      `json:"alive_writers"`
	RequiredWriters int      `json:"required_writers"`
	CoveragePct     float64  `json:"coverage_pct"`
}

// MeQuality — ответ /v1/runtime/me_quality.
//
// Enabled=false означает «middle proxy не используется», то есть судить не о
// чем. Это НЕ авария и не ошибка запроса: ошибку несёт конверт, а не это поле.
type MeQuality struct {
	Enabled bool   `json:"enabled"`
	Reason  string `json:"reason,omitempty"`
	Data    *struct {
		Counters   map[string]float64 `json:"counters"`
		RouteDrops map[string]float64 `json:"route_drops"`
		DCRtt      []DCRtt            `json:"dc_rtt"`
	} `json:"data"`
}

// UpstreamCounters — накопительные счётчики подключений к промежуточным
// серверам. Растут с момента старта движка, поэтому сами по себе о текущем
// состоянии не говорят: нужна дельта между опросами (см. watcher.go).
type UpstreamCounters struct {
	ConnectAttemptTotal           uint64 `json:"connect_attempt_total"`
	ConnectSuccessTotal           uint64 `json:"connect_success_total"`
	ConnectFailTotal              uint64 `json:"connect_fail_total"`
	ConnectFailfastHardErrorTotal uint64 `json:"connect_failfast_hard_error_total"`
}

// UpstreamQuality — ответ /v1/runtime/upstream_quality.
type UpstreamQuality struct {
	Enabled  bool              `json:"enabled"`
	Reason   string            `json:"reason,omitempty"`
	Counters *UpstreamCounters `json:"counters"`
}

// Health — ответ /v1/health.
type Health struct {
	Status   string `json:"status"`
	ReadOnly bool   `json:"read_only"`
}

// SystemInfo — то, что нам нужно из /v1/system/info.
//
// ProcessStartedAt — абсолютная метка запуска процесса. Перезапуск движка
// ловится по её смене, а не по падению uptime_seconds: абсолютное значение не
// требует арифметики дельт, не врёт при пропущенных опросах и устойчивее к
// сдвигу системных часов.
type SystemInfo struct {
	Version          string `json:"version"`
	ProcessStartedAt int64  `json:"process_started_at_epoch_secs"`
	UptimeSeconds    int64  `json:"uptime_seconds"`
}

// Summary — то, что нам нужно из /v1/stats/summary.
type Summary struct {
	UptimeSeconds int64 `json:"uptime_seconds"`
}
