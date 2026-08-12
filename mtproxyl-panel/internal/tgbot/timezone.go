package tgbot

import (
	"os"
	"strings"
	"sync"
	"time"
)

// tzRecheck — как часто перечитывать часовой пояс системы.
//
// Go определяет time.Local один раз за процесс, поэтому смена пояса на сервере
// работающей панелью не подхватывается: пока её не перезапустят, бот пишет
// время в прежней зоне. Панель этим не страдает — она отдаёт метку в UTC, а
// форматирует её браузер, — и расхождение между сообщением и интерфейсом
// выглядит поломкой. Перечитываем сами.
const tzRecheck = 5 * time.Minute

var (
	tzMu      sync.Mutex
	tzCached  *time.Location
	tzCheckAt time.Time
	tzNow     = time.Now // подменяется в тестах
	// tzSources — где смотреть имя зоны. Порядок важен: переменная окружения
	// перекрывает системную настройку, как и для всего остального в Go.
	tzEnv       = os.Getenv
	tzReadlink  = os.Readlink
	tzLoad      = time.LoadLocation
	tzLocalHint = "/etc/localtime"
)

// localZone возвращает текущий часовой пояс системы, перечитывая его не чаще
// раза в tzRecheck.
func localZone() *time.Location {
	tzMu.Lock()
	defer tzMu.Unlock()

	now := tzNow()
	if tzCached != nil && now.Sub(tzCheckAt) < tzRecheck {
		return tzCached
	}
	tzCheckAt = now

	if loc := loadZone(); loc != nil {
		tzCached = loc
	} else if tzCached == nil {
		// Ничего не вышло — остаёмся на том, что определил рантайм при старте.
		tzCached = time.Local
	}
	return tzCached
}

func loadZone() *time.Location {
	if name := strings.TrimSpace(tzEnv("TZ")); name != "" {
		if loc, err := tzLoad(name); err == nil {
			return loc
		}
	}
	// /etc/localtime обычно симлинк вида /usr/share/zoneinfo/Asia/Tashkent —
	// имя зоны достаётся из хвоста пути.
	target, err := tzReadlink(tzLocalHint)
	if err != nil {
		return nil
	}
	if i := strings.Index(target, "zoneinfo/"); i >= 0 {
		if loc, err := tzLoad(target[i+len("zoneinfo/"):]); err == nil {
			return loc
		}
	}
	return nil
}

// resetZoneCache нужен тестам: между случаями кэш не должен протекать.
func resetZoneCache() {
	tzMu.Lock()
	tzCached, tzCheckAt = nil, time.Time{}
	tzMu.Unlock()
}
