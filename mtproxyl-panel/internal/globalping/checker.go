package globalping

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"
)

const (
	// measurementWait bounds one measurement; probes normally answer in a few
	// seconds, and the slow ones are usually the blocked ones.
	measurementWait = 60 * time.Second
	pollInterval    = 2 * time.Second

	// manualCooldown keeps the «Проверить сейчас» button from burning the
	// hourly quota: every probe costs a credit.
	manualCooldown = time.Minute

	// startupDelay lets the engine come up before the first check, so a panel
	// and proxy starting together do not report a false outage.
	startupDelay = 10 * time.Second
)

// Target is what to check: the address probes connect to, the proxy port and
// the FakeTLS domain they should put in SNI.
type Target struct {
	Host string
	Port uint16
	SNI  string
}

// TargetProvider resolves the current target. It is called before every check
// because the port and the FakeTLS domain change under the operator's hands.
type TargetProvider func(ctx context.Context) (Target, error)

// Checker runs the availability check on a schedule and on demand.
type Checker struct {
	client         *Client
	store          *Store
	quota          *quota
	targetProvider TargetProvider
	interval       time.Duration
	probeLimit     int

	mu            sync.Mutex
	lastCheckTime time.Time
	// inFlight is non-nil while a check runs; other callers wait on it instead
	// of starting a second measurement and paying twice.
	inFlight chan struct{}
}

func NewChecker(apiToken string, targetProvider TargetProvider, interval time.Duration, probeLimit int) *Checker {
	if interval < time.Minute {
		interval = 15 * time.Minute
	}
	if probeLimit <= 0 || probeLimit > 50 {
		probeLimit = 20
	}
	c := &Checker{
		client:         NewClient(apiToken),
		store:          NewStore(),
		quota:          newQuota(apiToken),
		targetProvider: targetProvider,
		interval:       interval,
		probeLimit:     probeLimit,
	}
	// A schedule that cannot fit in the allowance is worth saying out loud: the
	// quota will throttle it anyway, but silently skipped checks look like the
	// feature is broken rather than misconfigured.
	if perHour := int(time.Hour/interval) * probeLimit; perHour > c.quota.budget {
		log.Printf("[globalping] интервал %v при %d зондах требует %d кредитов в час, "+
			"а лимит — %d: часть проверок будет пропущена. Увеличьте check_interval "+
			"или уменьшите probe_limit", interval, probeLimit, perHour, c.quota.budget)
	}
	return c
}

// Store gives the HTTP handlers access to the last result.
func (c *Checker) Store() *Store { return c.store }

// Quota reports the hourly allowance for the UI.
func (c *Checker) Quota() QuotaState { return c.quota.state() }

// Start runs checks until ctx is cancelled.
func (c *Checker) Start(ctx context.Context) {
	log.Printf("[globalping] проверка доступности включена: интервал %v, зондов %d", c.interval, c.probeLimit)

	select {
	case <-ctx.Done():
		return
	case <-time.After(startupDelay):
	}
	c.runScheduled(ctx)

	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Println("[globalping] проверка доступности остановлена")
			return
		case <-ticker.C:
			c.runScheduled(ctx)
		}
	}
}

// RunCheckNow is the manual trigger behind the «Проверить сейчас» button.
func (c *Checker) RunCheckNow(ctx context.Context) (*CheckResult, error) {
	c.mu.Lock()
	if ch := c.inFlight; ch != nil {
		// Someone (the schedule or another tab) is already measuring — wait
		// for that result instead of ordering a second one.
		c.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		if r := c.store.Get(); r != nil {
			return r, nil
		}
		return nil, fmt.Errorf("проверка завершилась без результата")
	}
	if since := time.Since(c.lastCheckTime); since < manualCooldown {
		c.mu.Unlock()
		return nil, fmt.Errorf("проверка была %d с назад — каждый зонд стоит квоты, подождите %d с",
			int(since.Seconds()), int((manualCooldown - since).Seconds()))
	}
	c.mu.Unlock()

	return c.doCheck(ctx)
}

func (c *Checker) runScheduled(ctx context.Context) {
	result, err := c.doCheck(ctx)
	if err != nil {
		var qe *QuotaError
		if errors.As(err, &qe) {
			// Не сбой: кредиты кончились, прошлый вердикт остаётся в силе.
			log.Printf("[globalping] плановая проверка пропущена — %s", qe)
			return
		}
		log.Printf("[globalping] проверка не удалась: %s", err)
		return
	}
	log.Printf("[globalping] проверка завершена: %.0f%% (%d из %d зондов)",
		result.Percentage, result.SuccessProbes, result.TotalProbes)
}

func (c *Checker) doCheck(ctx context.Context) (*CheckResult, error) {
	c.mu.Lock()
	if ch := c.inFlight; ch != nil {
		c.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		if r := c.store.Get(); r != nil {
			return r, nil
		}
		return nil, fmt.Errorf("проверка завершилась без результата")
	}
	// Отказ по квоте — не результат проверки, а отказ её начинать: ничего не
	// потрачено и не измерено, поэтому прошлый вердикт не затирается.
	if err := c.quota.check(c.probeLimit); err != nil {
		c.mu.Unlock()
		return nil, err
	}
	done := make(chan struct{})
	c.inFlight = done
	c.lastCheckTime = time.Now()
	c.mu.Unlock()

	result, err := c.measure(ctx)

	c.mu.Lock()
	c.lastCheckTime = time.Now()
	c.inFlight = nil
	c.mu.Unlock()
	close(done)

	if err != nil {
		// The failure is worth keeping: the page has to explain why there is
		// no fresh verdict instead of showing a stale one as current.
		c.store.Set(&CheckResult{CheckedAt: time.Now(), Error: err.Error(), Level: LevelRed})
		return nil, err
	}
	c.store.Set(result)
	return result, nil
}

func (c *Checker) measure(ctx context.Context) (*CheckResult, error) {
	target, err := c.targetProvider(ctx)
	if err != nil {
		return nil, fmt.Errorf("не удалось определить, что проверять: %w", err)
	}
	if target.Host == "" {
		return nil, fmt.Errorf("не удалось определить адрес сервера — задайте override_host в секции [globalping]")
	}
	if target.Port == 0 {
		target.Port = 443
	}

	req := BuildMeasurementRequest(target.Host, target.Port, target.SNI, c.probeLimit)
	created, err := c.client.CreateMeasurement(ctx, req)
	if err != nil {
		// Сервис говорит, что кредитов нет: его слово важнее локального счёта,
		// который после перезапуска панели начинается с нуля, а квота — нет.
		var rle *RateLimitError
		if errors.As(err, &rle) {
			c.quota.blockFor(rle.RetryIn)
		}
		return nil, err
	}
	// Платим за реально задействованные зонды: сервис не всегда даёт столько,
	// сколько попросили, и списывать по запрошенному значило бы занижать
	// остаток и пропускать проверки, которые ещё влезали.
	cost := created.ProbesCount
	if cost <= 0 {
		cost = c.probeLimit
	}
	c.quota.record(cost)

	measurement, err := c.client.AwaitMeasurement(ctx, created.ID, measurementWait, pollInterval)
	if err != nil {
		return nil, err
	}
	if len(measurement.Results) == 0 {
		return nil, fmt.Errorf("ни один российский зонд не взялся за проверку — повторите позже")
	}

	result := AnalyzeMeasurement(measurement)
	// Target в ответе API — это то, что мы просили проверить; для человека
	// важнее видеть и порт, и SNI, по которому шло рукопожатие.
	if target.SNI != "" {
		result.Target = fmt.Sprintf("%s:%d (SNI: %s)", target.Host, target.Port, target.SNI)
	} else {
		result.Target = fmt.Sprintf("%s:%d", target.Host, target.Port)
	}
	return result, nil
}
