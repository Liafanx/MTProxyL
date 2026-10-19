package mtproxylctl

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
)

// SnapCache держит результат дорогого вызова CLI (bash под sudo — около
// секунды на сотнях пользователей) и отдаёт его сразу.
//
//   - Пока отслеживаемые файлы не менялись и прошло меньше Fresh — отдаём
//     как есть.
//   - Файлы не менялись, но Fresh вышел — отдаём прежнее и обновляем в фоне:
//     так меняются только счётчики трафика, им секунды задержки не вредят.
//   - Файлы поменялись (правка из меню, панели или API) или кэш сброшен —
//     ждём свежий результат: устаревших пользователей и ссылок не отдаём.
//
// Одновременные запросы ждут один вызов CLI.
type SnapCache[T any] struct {
	Load  func(ctx context.Context) (T, error)
	Watch []string
	Fresh time.Duration
	// Timeout — предел одного вызова Load, который идёт мимо контекста
	// запроса: ушедший клиент не должен обрывать загрузку для остальных.
	Timeout time.Duration

	mu       sync.Mutex
	have     bool
	val      T
	err      error
	at       time.Time
	sig      string
	inFlight chan struct{}
	// inFlightSig и inFlightGen — подпись файлов и поколение сброса на
	// момент запуска текущей загрузки.
	inFlightSig string
	inFlightGen int
	gen         int
}

// Get возвращает снимок по правилам выше.
func (c *SnapCache[T]) Get(ctx context.Context) (T, error) {
	for {
		sig := c.signature()
		c.mu.Lock()
		if c.have && c.err == nil && sig == c.sig {
			v := c.val
			if time.Since(c.at) >= c.fresh() && c.inFlight == nil {
				c.startLocked(sig)
			}
			c.mu.Unlock()
			return v, nil
		}
		// Загрузка, начатая до правки, прочитала бы старое — ждём её и
		// запускаем свою.
		ch, stale := c.inFlight, c.inFlightSig != sig || c.inFlightGen != c.gen
		if ch == nil {
			ch, stale = c.startLocked(sig), false
		}
		c.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			var zero T
			return zero, ctx.Err()
		}
		if stale {
			continue
		}
		c.mu.Lock()
		v, err := c.val, c.err
		c.mu.Unlock()
		return v, err
	}
}

// Put кладёт значение, посчитанное без CLI (после своей записи), как свежее:
// пачка записей подряд не запускает CLI ради снимка после каждой, обновление
// придёт как обычно, через Fresh. Загрузки, начатые раньше, его не перезапишут.
func (c *SnapCache[T]) Put(v T) {
	sig := c.signature()
	c.mu.Lock()
	c.gen++
	c.val, c.err, c.have, c.sig, c.at = v, nil, true, sig, time.Now()
	c.mu.Unlock()
}

// Peek — последнее загруженное значение без проверок и ожидания.
func (c *SnapCache[T]) Peek() (T, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.val, c.have && c.err == nil
}

// Invalidate сбрасывает кэш: следующий Get дождётся свежего результата.
func (c *SnapCache[T]) Invalidate() {
	c.mu.Lock()
	c.have = false
	c.sig = ""
	c.gen++
	c.mu.Unlock()
}

func (c *SnapCache[T]) fresh() time.Duration {
	if c.Fresh > 0 {
		return c.Fresh
	}
	return 10 * time.Second
}

// startLocked запускает загрузку; c.mu уже взят. sig снята до загрузки:
// правка во время загрузки даст расхождение, и следующий Get загрузит заново.
func (c *SnapCache[T]) startLocked(sig string) chan struct{} {
	ch := make(chan struct{})
	c.inFlight, c.inFlightSig, c.inFlightGen = ch, sig, c.gen
	gen := c.gen
	go func() {
		timeout := c.Timeout
		if timeout <= 0 {
			timeout = 2 * time.Minute
		}
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		v, err := c.Load(ctx)
		cancel()
		c.mu.Lock()
		if (err == nil && gen == c.gen) || !c.have {
			c.val, c.err = v, err
		}
		// Ошибку фонового обновления не выдаём поверх рабочего снимка, но
		// и свежим его не считаем — следующий запрос попробует снова.
		// Загрузка до сброса — не свежая: её только отдадут ждавшим.
		if err == nil && gen == c.gen {
			c.have, c.at, c.sig = true, time.Now(), sig
		} else if !c.have {
			c.at, c.sig = time.Now(), ""
		}
		c.inFlight = nil
		c.mu.Unlock()
		close(ch)
	}()
	return ch
}

// signature — время изменения, размер и inode отслеживаемых путей. Хватает
// права на stat: сами файлы API и панели читать не нужно.
func (c *SnapCache[T]) signature() string {
	var b strings.Builder
	for _, p := range c.Watch {
		st, err := os.Stat(p)
		if err != nil {
			b.WriteString(p + ":-;")
			continue
		}
		var ino uint64
		if s, ok := st.Sys().(*syscall.Stat_t); ok {
			ino = s.Ino
		}
		fmt.Fprintf(&b, "%s:%d:%d:%d;", p, st.ModTime().UnixNano(), st.Size(), ino)
	}
	return b.String()
}
