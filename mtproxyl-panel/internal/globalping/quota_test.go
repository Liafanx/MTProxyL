package globalping

import (
	"testing"
	"time"
)

// newTestQuota гоняет счётчик по часам вручную: окно длиной в час, ждать его
// по-настоящему не вариант.
func newTestQuota(token string, now *time.Time) *quota {
	q := newQuota(token)
	q.now = func() time.Time { return *now }
	return q
}

func TestQuotaCountsSpentCredits(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	for i := 0; i < 12; i++ {
		q.record(20)
	}
	st := q.state()
	if st.Spent != 240 {
		t.Errorf("Spent = %d, ожидалось 240", st.Spent)
	}
	if st.Budget != 250 {
		t.Errorf("Budget = %d, ожидалось 250", st.Budget)
	}
	if st.Remaining != 10 {
		t.Errorf("Remaining = %d, ожидалось 10", st.Remaining)
	}
}

// Счётчик перерасход показывает, но ничего не запрещает: лимит объявляет сервис.
func TestQuotaDoesNotBlockOverspend(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	for i := 0; i < 20; i++ {
		q.record(20) // 400 при справочных 250
	}
	st := q.state()
	if st.Spent != 400 {
		t.Errorf("Spent = %d, ожидалось 400", st.Spent)
	}
	if st.Remaining != 0 {
		t.Errorf("Remaining = %d, ожидалось 0 (в минус не уходим)", st.Remaining)
	}
}

func TestQuotaTokenRaisesBudget(t *testing.T) {
	now := time.Now()
	q := newTestQuota("gp_token", &now)

	if st := q.state(); st.Budget != 500 || !st.HasToken {
		t.Errorf("с токеном Budget = %d, HasToken = %v; ожидалось 500 и true", st.Budget, st.HasToken)
	}
}

// Токен можно поменять на ходу: счётчик при этом не сбрасывается.
func TestQuotaSetBudgetKeepsCounter(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)
	q.record(60)

	q.setBudgetFor("gp_token")
	st := q.state()
	if st.Budget != 500 {
		t.Errorf("Budget = %d, ожидалось 500", st.Budget)
	}
	if st.Spent != 60 {
		t.Errorf("Spent = %d, ожидалось 60 — счётчик не должен сбрасываться", st.Spent)
	}
	if !st.HasToken {
		t.Error("HasToken должен стать true")
	}

	q.setBudgetFor("")
	if st := q.state(); st.Budget != 250 || st.HasToken {
		t.Errorf("после снятия токена Budget = %d, HasToken = %v", st.Budget, st.HasToken)
	}
}

// Кредиты возвращаются через час после списания, а не в начале часа.
func TestQuotaCreditsReturnAfterAnHour(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	q.record(100)
	if st := q.state(); st.Spent != 100 {
		t.Fatalf("Spent = %d, ожидалось 100", st.Spent)
	}

	now = now.Add(59 * time.Minute)
	if st := q.state(); st.Spent != 100 {
		t.Errorf("через 59 минут Spent = %d, ожидалось 100", st.Spent)
	}

	now = now.Add(2 * time.Minute)
	if st := q.state(); st.Spent != 0 {
		t.Errorf("через час Spent = %d, ожидалось 0", st.Spent)
	}
}

// 429 обнуляет остаток в показаниях, пока сервис не отпустит.
func TestQuotaShowsBlockFrom429(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	q.blockFor(30 * time.Minute)
	st := q.state()
	if st.Remaining != 0 {
		t.Errorf("Remaining во время блокировки = %d, ожидалось 0", st.Remaining)
	}
	if st.ResetInSeconds < 29*60 || st.ResetInSeconds > 31*60 {
		t.Errorf("ResetInSeconds = %d, ожидалось около %d", st.ResetInSeconds, 30*60)
	}

	now = now.Add(31 * time.Minute)
	if st := q.state(); st.Remaining != 250 {
		t.Errorf("после истечения блокировки Remaining = %d, ожидалось 250", st.Remaining)
	}
}

func TestQuotaRecordsActualProbeCount(t *testing.T) {
	now := time.Now()
	q := newTestQuota("", &now)

	q.record(7)
	st := q.state()
	if st.Spent != 7 || st.Remaining != 243 {
		t.Errorf("Spent = %d, Remaining = %d; ожидалось 7 и 243", st.Spent, st.Remaining)
	}
}
