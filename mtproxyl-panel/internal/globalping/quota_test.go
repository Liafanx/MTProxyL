package globalping

import (
	"errors"
	"testing"
	"time"
)

// newTestQuota gives the ledger a clock the test drives by hand: the window is
// an hour long, and waiting it out for real is not an option.
func newTestQuota(token string, now *time.Time) *quota {
	q := newQuota(token)
	q.now = func() time.Time { return *now }
	return q
}

func TestQuotaAnonymousBudgetIs250(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	// 12 проверок по 20 зондов — 240 кредитов, всё ещё в лимите.
	for i := 0; i < 12; i++ {
		if err := q.check(20); err != nil {
			t.Fatalf("проверка %d отклонена раньше времени: %s", i+1, err)
		}
		q.record(20)
	}
	if got := q.state().Spent; got != 240 {
		t.Errorf("Spent = %d, ожидалось 240", got)
	}
	// Тринадцатая (260 > 250) уже не влезает.
	err := q.check(20)
	if err == nil {
		t.Fatal("13-я проверка должна быть отклонена: 260 > 250")
	}
	var qe *QuotaError
	if !errors.As(err, &qe) {
		t.Errorf("ожидался *QuotaError, получен %T", err)
	}
}

func TestQuotaTokenDoublesBudget(t *testing.T) {
	now := time.Now()
	q := newTestQuota("gp_token", &now)

	if got := q.state().Budget; got != 500 {
		t.Errorf("Budget с токеном = %d, ожидалось 500", got)
	}
	for i := 0; i < 25; i++ {
		if err := q.check(20); err != nil {
			t.Fatalf("проверка %d отклонена раньше времени: %s", i+1, err)
		}
		q.record(20)
	}
	if err := q.check(20); err == nil {
		t.Error("26-я проверка должна быть отклонена: 520 > 500")
	}
}

// Кредиты возвращаются через час после списания, а не в начале часа.
func TestQuotaCreditsReturnAfterAnHour(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	for i := 0; i < 12; i++ {
		q.record(20)
	}
	if err := q.check(20); err == nil {
		t.Fatal("лимит должен быть исчерпан")
	}

	// Через 59 минут ещё ничего не вернулось.
	now = now.Add(59 * time.Minute)
	if err := q.check(20); err == nil {
		t.Error("через 59 минут кредиты возвращаться не должны")
	}

	// Через час первое списание уходит из окна и место освобождается.
	now = now.Add(2 * time.Minute)
	if err := q.check(20); err != nil {
		t.Errorf("через час проверка должна пройти, получено: %s", err)
	}
}

// 429 от сервиса важнее локального счёта: после перезапуска панели ledger
// пустой, а квота на стороне Globalping — нет.
func TestQuotaRespects429Block(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	if err := q.check(20); err != nil {
		t.Fatalf("пустой ledger не должен ничего отклонять: %s", err)
	}

	q.blockFor(30 * time.Minute)
	if err := q.check(20); err == nil {
		t.Fatal("после 429 проверки должны отклоняться")
	}
	if got := q.state().Remaining; got != 0 {
		t.Errorf("Remaining во время блокировки = %d, ожидалось 0", got)
	}

	now = now.Add(31 * time.Minute)
	if err := q.check(20); err != nil {
		t.Errorf("после истечения блокировки проверка должна пройти: %s", err)
	}
}

// Списываем по числу реально задействованных зондов: сервис не всегда даёт
// столько, сколько попросили.
func TestQuotaRecordsActualProbeCount(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	q.record(7)
	st := q.state()
	if st.Spent != 7 {
		t.Errorf("Spent = %d, ожидалось 7", st.Spent)
	}
	if st.Remaining != 243 {
		t.Errorf("Remaining = %d, ожидалось 243", st.Remaining)
	}
}

func TestQuotaStateReportsResetCountdown(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	q.record(20)
	now = now.Add(20 * time.Minute)

	st := q.state()
	// Первое списание уходит из окна через 40 минут.
	if st.ResetInSeconds < 39*60 || st.ResetInSeconds > 41*60 {
		t.Errorf("ResetInSeconds = %d, ожидалось около %d", st.ResetInSeconds, 40*60)
	}
	if st.HasToken {
		t.Error("HasToken должен быть false без токена")
	}
}
