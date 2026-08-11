package tgbot

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

func sampleResult(total, ok int) *globalping.CheckResult {
	r := &globalping.CheckResult{
		TotalProbes:   total,
		SuccessProbes: ok,
		CheckedAt:     time.Date(2026, 8, 11, 17, 21, 51, 0, time.Local),
		Level:         globalping.LevelGreen,
	}
	if total > 0 {
		r.Percentage = float64(ok) / float64(total) * 100
	}
	for i := 0; i < total; i++ {
		p := globalping.ProbeDetail{City: fmt.Sprintf("Город-%d", i), Network: "Провайдер", TLSSuccess: i < ok}
		if !p.TLSSuccess {
			p.Error = "соединение не установлено"
		}
		r.Probes = append(r.Probes, p)
	}
	return r
}

func baseView(r *globalping.CheckResult) View {
	return View{
		Result:    r,
		Target:    globalping.Target{Host: "tg-plug.example.uz", Port: 443, SNI: "tg-plug.example.uz"},
		Quota:     globalping.QuotaState{Budget: 250, Remaining: 180},
		AutoCheck: true,
		Interval:  15 * time.Minute,
		Threshold: 60,
		Now:       time.Date(2026, 8, 11, 17, 30, 0, 0, time.Local),
	}
}

func TestRenderStatusHasSummaryAndProbes(t *testing.T) {
	out := RenderStatus(baseView(sampleResult(20, 19)))

	for _, want := range []string{
		"Доступность из РФ — 95%",
		"Зондов: <b>19 / 20</b>",
		"tg-plug.example.uz:443",
		"SNI:",
		"Проверено: 11.08.2026, 17:21:51",
		"Автопроверка: включена, раз в 15 мин",
		"Квота Globalping: 180 / 250",
		"<b>Зонды (20):</b>",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("в сообщении нет %q\n---\n%s", want, out)
		}
	}
	if strings.Count(out, "✅") != 19 || strings.Count(out, "❌") != 1 {
		t.Errorf("ожидалось 19 успешных и 1 упавший зонд:\n%s", out)
	}
}

// Имена провайдеров приходят какими угодно. Неэкранированный «&» ломает
// разметку, и Telegram отвечает 400 вместо сообщения.
func TestRenderStatusEscapesProviderNames(t *testing.T) {
	r := sampleResult(1, 0)
	r.Probes[0].Network = `AT&T <Wireless>`
	r.Probes[0].City = `Москва & область`
	r.Probes[0].Error = `сброс <соединения> & таймаут`

	out := RenderStatus(baseView(r))

	if strings.Contains(out, "AT&T <Wireless>") {
		t.Errorf("имя провайдера не экранировано:\n%s", out)
	}
	for _, want := range []string{"AT&amp;T", "&lt;Wireless&gt;", "Москва &amp; область"} {
		if !strings.Contains(out, want) {
			t.Errorf("нет экранированного %q\n---\n%s", want, out)
		}
	}
}

func TestRenderStatusEscapesTargetAndSNI(t *testing.T) {
	v := baseView(sampleResult(1, 1))
	v.Target.Host = "evil<b>.example"
	v.Target.SNI = "evil&sni"

	out := RenderStatus(v)

	if strings.Contains(out, "evil<b>.example") {
		t.Errorf("хост не экранирован:\n%s", out)
	}
	if !strings.Contains(out, "evil&amp;sni") {
		t.Errorf("SNI не экранирован:\n%s", out)
	}
}

// 50 зондов с длинными именами — предельный случай: probe_limit больше 50 не
// бывает, а имена провайдеров бывают очень длинными.
func TestRenderStatusFitsTelegramLimit(t *testing.T) {
	r := sampleResult(50, 25)
	long := strings.Repeat("Очень Длинное Имя Провайдера ", 6)
	for i := range r.Probes {
		r.Probes[i].Network = long
		r.Probes[i].City = strings.Repeat("Населённый Пункт ", 4)
		r.Probes[i].Error = strings.Repeat("развёрнутое описание отказа ", 5)
	}

	out := RenderStatus(baseView(r))

	if n := len([]rune(out)); n > MessageLimit {
		t.Fatalf("длина сообщения %d рун, предел %d", n, MessageLimit)
	}
	if !strings.Contains(out, "и ещё") {
		t.Errorf("обрезка произошла молча, без строки об остатке:\n%s", out[len(out)-300:])
	}
}

func TestRenderStatusShortMessageIsNotTruncated(t *testing.T) {
	out := RenderStatus(baseView(sampleResult(20, 19)))
	if strings.Contains(out, "и ещё") {
		t.Errorf("короткое сообщение обрезано зря:\n%s", out)
	}
}

func TestRenderStatusDownBanner(t *testing.T) {
	v := baseView(sampleResult(20, 11))
	v.Banner = BannerDown
	v.PrevPercentage = 95
	v.PrevKnown = true
	v.AlertSince = v.Now.Add(-25 * time.Minute)

	out := RenderStatus(v)

	for _, want := range []string{
		"ПАДЕНИЕ ДОСТУПНОСТИ",
		"Было 95% → стало 55% (11 / 20)",
		"Длится 25 мин · порог 60%",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("в алерте нет %q\n---\n%s", want, out)
		}
	}
}

func TestRenderStatusRecoveredBanner(t *testing.T) {
	v := baseView(sampleResult(20, 18))
	v.Banner = BannerRecovered
	v.PrevPercentage = 55
	v.PrevKnown = true
	v.AlertSince = v.Now.Add(-90 * time.Minute)

	out := RenderStatus(v)

	if !strings.Contains(out, "ДОСТУПНОСТЬ ВОССТАНОВЛЕНА") {
		t.Errorf("нет шапки восстановления:\n%s", out)
	}
	if !strings.Contains(out, "Авария длилась 1 ч 30 мин") {
		t.Errorf("нет длительности аварии:\n%s", out)
	}
}

// Сорвавшаяся проверка не обнуляет доступность: показываем причину и рядом —
// последний известный вердикт, а не 0%.
func TestRenderStatusFailureKeepsLastVerdict(t *testing.T) {
	v := baseView(sampleResult(20, 19))
	v.Failure = &Failure{Reason: "сервис проверки не отвечает", At: v.Now}

	out := RenderStatus(v)

	for _, want := range []string{
		"Проверка не удалась",
		"сервис проверки не отвечает",
		"Ниже — последний известный вердикт",
		"Доступность из РФ — 95%",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("нет %q\n---\n%s", want, out)
		}
	}
	if strings.Contains(out, "— 0%") {
		t.Errorf("неудача показана как нулевая доступность:\n%s", out)
	}
}

func TestRenderStatusFailureWithoutAnyVerdict(t *testing.T) {
	v := baseView(nil)
	v.Failure = &Failure{Reason: "некуда стучаться", At: v.Now}

	out := RenderStatus(v)

	if !strings.Contains(out, "Удачных проверок пока не было") {
		t.Errorf("нет объяснения про отсутствие вердикта:\n%s", out)
	}
}

func TestRenderStatusNoResultYet(t *testing.T) {
	out := RenderStatus(baseView(nil))
	if !strings.Contains(out, "Проверок ещё не было") {
		t.Errorf("нет заглушки до первой проверки:\n%s", out)
	}
}

func TestRenderStatusIPBlock(t *testing.T) {
	v := baseView(sampleResult(1, 1))
	v.Host = HostInfo{Addrs: []string{"203.0.113.10"}, ServerIP: "203.0.113.10"}

	out := RenderStatus(v)

	if !strings.Contains(out, "A-запись: <code>203.0.113.10</code>") {
		t.Errorf("нет A-записи:\n%s", out)
	}
	if !strings.Contains(out, "IP сервера: <code>203.0.113.10</code>") {
		t.Errorf("нет IP сервера:\n%s", out)
	}
	if strings.Contains(out, "ведёт не на этот сервер") {
		t.Errorf("предупреждение о расхождении при совпадающих адресах:\n%s", out)
	}
}

func TestRenderStatusIPMismatchWarning(t *testing.T) {
	v := baseView(sampleResult(1, 1))
	v.Host = HostInfo{Addrs: []string{"203.0.113.10"}, ServerIP: "198.51.100.7", Mismatch: true}

	out := RenderStatus(v)

	if !strings.Contains(out, "ведёт не на этот сервер") {
		t.Errorf("нет предупреждения о расхождении:\n%s", out)
	}
}

func TestRenderStatusAutoCheckOff(t *testing.T) {
	v := baseView(sampleResult(2, 2))
	v.AutoCheck = false

	out := RenderStatus(v)

	if !strings.Contains(out, "Автопроверка: выключена") {
		t.Errorf("не показано, что автопроверка выключена:\n%s", out)
	}
}

func TestHumanInterval(t *testing.T) {
	cases := map[time.Duration]string{
		15 * time.Minute:                  "15 мин",
		time.Hour:                         "1 ч",
		90 * time.Minute:                  "1 ч 30 мин",
		0:                                 "15 мин",
		6*time.Hour + 30*time.Minute:      "6 ч 30 мин",
		time.Duration(45) * time.Minute:   "45 мин",
		time.Duration(2) * time.Hour:      "2 ч",
		time.Duration(3660) * time.Second: "1 ч 1 мин",
	}
	for d, want := range cases {
		if got := humanInterval(d); got != want {
			t.Errorf("humanInterval(%v) = %q, want %q", d, got, want)
		}
	}
}

func TestRenderStartReplyCarriesChatID(t *testing.T) {
	out := RenderStartReply(123456789, false)
	if !strings.Contains(out, "<code>123456789</code>") {
		t.Errorf("в ответе на /start нет chat_id:\n%s", out)
	}
	if !strings.Contains(out, "ID админа") {
		t.Errorf("не сказано, куда вписывать ID:\n%s", out)
	}
}
