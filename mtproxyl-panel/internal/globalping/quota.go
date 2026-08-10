package globalping

import (
	"fmt"
	"sync"
	"time"
)

// Globalping bills one credit per probe and refills the allowance hourly.
// Anonymous callers get 250 credits an hour per IP; a free token doubles it.
const (
	anonymousHourlyCredits = 250
	tokenHourlyCredits     = 500

	creditWindow = time.Hour
)

// quota — счётчик потраченных кредитов, а не сторож. Лимит объявляет сам
// сервис ответом 429: своя арифметика тут только гадала бы, а отказывать по
// догадке хуже, чем отдать решение тому, кто считает по-настоящему.
// Скользящий час, а не фиксированное окно: кредиты возвращаются через час
// после списания.
type quota struct {
	mu     sync.Mutex
	budget int
	spends []creditSpend
	// blockedUntil is set from a 429: the service knows better than the local
	// tally, which starts empty after a restart while the allowance may not be.
	blockedUntil time.Time
	now          func() time.Time
}

type creditSpend struct {
	at   time.Time
	cost int
}

func newQuota(apiToken string) *quota {
	budget := anonymousHourlyCredits
	if apiToken != "" {
		budget = tokenHourlyCredits
	}
	return &quota{budget: budget, now: time.Now}
}

// record books credits actually spent. The cost is the number of probes the
// service says it engaged, which is not always the number asked for.
func (q *quota) record(cost int) {
	if cost <= 0 {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	now := q.now()
	q.prune(now)
	q.spends = append(q.spends, creditSpend{at: now, cost: cost})
}

// blockFor marks the allowance as gone until the service says it is back.
func (q *quota) blockFor(d time.Duration) {
	if d <= 0 {
		d = creditWindow
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.blockedUntil = q.now().Add(d)
}

// state is what the UI shows so the operator can see why a check was refused.
func (q *quota) state() QuotaState {
	q.mu.Lock()
	defer q.mu.Unlock()

	now := q.now()
	q.prune(now)
	spent := q.spentLocked()
	remaining := q.budget - spent
	if remaining < 0 {
		remaining = 0
	}

	st := QuotaState{
		Budget:    q.budget,
		Spent:     spent,
		Remaining: remaining,
		HasToken:  !q.tokenlessLocked(),
	}
	if now.Before(q.blockedUntil) {
		st.Remaining = 0
		st.ResetInSeconds = int(q.blockedUntil.Sub(now).Seconds())
	} else if len(q.spends) > 0 {
		st.ResetInSeconds = int(q.spends[0].at.Add(creditWindow).Sub(now).Seconds())
	}
	if st.ResetInSeconds < 0 {
		st.ResetInSeconds = 0
	}
	return st
}

// prune drops spends that have aged out of the window. Caller holds the lock.
func (q *quota) prune(now time.Time) {
	cutoff := now.Add(-creditWindow)
	i := 0
	for i < len(q.spends) && !q.spends[i].at.After(cutoff) {
		i++
	}
	q.spends = q.spends[i:]
	if now.After(q.blockedUntil) {
		q.blockedUntil = time.Time{}
	}
}

func (q *quota) spentLocked() int {
	total := 0
	for _, s := range q.spends {
		total += s.cost
	}
	return total
}

// Вызывается из state(), которая уже держит мьютекс: sync.Mutex не рекурсивный.
func (q *quota) tokenlessLocked() bool { return q.budget == anonymousHourlyCredits }

// setBudgetFor меняет справочный лимит под новый токен, не сбрасывая счётчик.
func (q *quota) setBudgetFor(token string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if token != "" {
		q.budget = tokenHourlyCredits
	} else {
		q.budget = anonymousHourlyCredits
	}
}

// QuotaState is the hourly allowance as the panel sees it.
type QuotaState struct {
	Budget         int  `json:"budget"`
	Spent          int  `json:"spent"`
	Remaining      int  `json:"remaining"`
	ResetInSeconds int  `json:"reset_in_seconds"`
	HasToken       bool `json:"has_token"`
}

func humanDuration(d time.Duration) string {
	if d < time.Minute {
		secs := int(d.Seconds())
		if secs < 1 {
			secs = 1
		}
		return fmt.Sprintf("%d с", secs)
	}
	return fmt.Sprintf("%d мин", int(d.Minutes())+1)
}
