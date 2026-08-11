package tgbot

import (
	"fmt"
	"html"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

// Banner — шапка над телом сообщения. Тело у всех трёх видов одинаковое:
// меняется только то, что сверху, потому что сообщение в чате одно и то же.
type Banner int

const (
	// BannerNone — обычный статус, пришёл тихой правкой.
	BannerNone Banner = iota
	// BannerDown — доступность ушла ниже порога. Такое сообщение отправляется
	// заново, а не правится: правка не даёт звука, и её легко проспать.
	BannerDown
	// BannerRecovered — вернулись выше порога.
	BannerRecovered
)

// Failure — сорвавшаяся попытка проверки. Живёт отдельно от вердикта: неудача
// не обнуляет доступность, она лишь означает, что свежих цифр нет.
type Failure struct {
	Reason string
	At     time.Time
}

// View — всё, из чего собирается сообщение.
type View struct {
	// Result — последний удачный вердикт. nil, если проверок ещё не было.
	Result *globalping.CheckResult
	// Failure — непусто, если последняя попытка сорвалась.
	Failure *Failure

	Target    globalping.Target
	Host      HostInfo
	Quota     globalping.QuotaState
	AutoCheck bool
	Interval  time.Duration

	Banner Banner
	// PrevPercentage — доступность до события, для строки «было X% → стало Y%».
	// PrevKnown отличает «раньше было 0%» от «раньше ничего не было».
	PrevPercentage float64
	PrevKnown      bool
	// AlertSince — когда началась авария, для «длится N».
	AlertSince time.Time
	Threshold  float64
	Now        time.Time
}

const (
	dotGreen  = "🟢"
	dotYellow = "🟡"
	dotRed    = "🔴"
)

// RenderStatus собирает текст сообщения. Разметка — HTML: она прощает
// незакрытые символы лучше Markdown, а имена провайдеров у зондов приходят
// какими угодно.
func RenderStatus(v View) string {
	var b strings.Builder

	writeBanner(&b, v)

	if v.Failure != nil {
		b.WriteString("⚠️ <b>Проверка не удалась</b>\n")
		b.WriteString(esc(v.Failure.Reason) + "\n")
		b.WriteString("Попытка: " + stamp(v.Failure.At) + "\n")
		if v.Result == nil {
			b.WriteString("\nУдачных проверок пока не было.\n")
			writeFooter(&b, v)
			return clamp(b.String())
		}
		b.WriteString("\nНиже — последний известный вердикт.\n\n")
	}

	if v.Result == nil {
		b.WriteString("Проверок ещё не было — первая пройдёт в ближайшие минуты.\n")
		writeFooter(&b, v)
		return clamp(b.String())
	}

	r := v.Result
	fmt.Fprintf(&b, "%s <b>Доступность из РФ — %.0f%%</b>\n\n", levelDot(r.Level), r.Percentage)
	fmt.Fprintf(&b, "Зондов: <b>%d / %d</b>\n", r.SuccessProbes, r.TotalProbes)

	writeTarget(&b, v)
	b.WriteString("Проверено: " + stamp(r.CheckedAt) + "\n")
	writeFooter(&b, v)

	writeProbes(&b, r)
	return clamp(b.String())
}

// clamp — последняя страховка от предела Telegram. Список зондов режется своей
// логикой, но шапка события, длинная цель и текст отказа складываются
// независимо, а сообщение длиннее предела не отправляется вовсе — вместо
// статуса пришло бы ничего. Режем по границе строки: теги разметки не
// пересекают перевод строки, поэтому такой обрыв не ломает HTML.
func clamp(s string) string {
	runes := []rune(s)
	if len(runes) <= MessageLimit {
		return s
	}
	cut := string(runes[:MessageLimit-1])
	if i := strings.LastIndexByte(cut, '\n'); i > 0 {
		cut = cut[:i+1]
	}
	return cut + "…"
}

func writeBanner(b *strings.Builder, v View) {
	switch v.Banner {
	case BannerDown:
		b.WriteString("🚨 <b>ПАДЕНИЕ ДОСТУПНОСТИ</b>\n")
		writeChange(b, v)
		if since := duration(v.Now, v.AlertSince); since != "" {
			fmt.Fprintf(b, "Длится %s · порог %.0f%%\n", since, v.Threshold)
		} else {
			fmt.Fprintf(b, "Порог алерта: %.0f%%\n", v.Threshold)
		}
		b.WriteString("Часто это значит, что адрес попал под фильтр у части операторов.\n")
		b.WriteString("\n──────────\n\n")
	case BannerRecovered:
		b.WriteString("✅ <b>ДОСТУПНОСТЬ ВОССТАНОВЛЕНА</b>\n")
		writeChange(b, v)
		if since := duration(v.Now, v.AlertSince); since != "" {
			b.WriteString("Авария длилась " + since + "\n")
		}
		b.WriteString("\n──────────\n\n")
	}
}

func writeChange(b *strings.Builder, v View) {
	if v.Result == nil {
		return
	}
	if !v.PrevKnown {
		// Первый вердикт в жизни бота: сравнивать не с чем, и «Было 0%» здесь
		// было бы выдумкой.
		fmt.Fprintf(b, "Сейчас %.0f%% (%d / %d)\n",
			v.Result.Percentage, v.Result.SuccessProbes, v.Result.TotalProbes)
		return
	}
	fmt.Fprintf(b, "Было %.0f%% → стало %.0f%% (%d / %d)\n",
		v.PrevPercentage, v.Result.Percentage, v.Result.SuccessProbes, v.Result.TotalProbes)
}

func writeTarget(b *strings.Builder, v View) {
	host := v.Target.Host
	if host == "" && v.Result != nil {
		// Цель не переспросили — берём ту, что записал сам вердикт.
		host = v.Result.Target
	}
	if host == "" {
		return
	}
	if v.Target.Host != "" && v.Target.Port != 0 {
		fmt.Fprintf(b, "Цель: <code>%s:%d</code>\n", esc(v.Target.Host), v.Target.Port)
	} else {
		fmt.Fprintf(b, "Цель: <code>%s</code>\n", esc(host))
	}
	if v.Target.SNI != "" {
		b.WriteString("  SNI: <code>" + esc(v.Target.SNI) + "</code>\n")
	}
	if len(v.Host.Addrs) > 0 {
		b.WriteString("  A-запись: <code>" + esc(strings.Join(v.Host.Addrs, ", ")) + "</code>\n")
	}
	if v.Host.ServerIP != "" {
		b.WriteString("  IP сервера: <code>" + esc(v.Host.ServerIP) + "</code>\n")
	}
	if v.Host.Mismatch {
		b.WriteString("  ⚠️ домен ведёт не на этот сервер — проверьте DNS, если переезжали\n")
	}
}

func writeFooter(b *strings.Builder, v View) {
	if v.AutoCheck {
		b.WriteString("Автопроверка: включена, раз в " + humanInterval(v.Interval) + "\n")
	} else {
		b.WriteString("Автопроверка: выключена — только по кнопке\n")
	}
	if v.Quota.Budget > 0 {
		fmt.Fprintf(b, "Квота Globalping: %d / %d кредитов\n", v.Quota.Remaining, v.Quota.Budget)
	}
}

// writeProbes выкладывает все зонды и обрезает хвост, если сообщение упирается
// в предел Telegram. Резать приходится по-настоящему: имена провайдеров бывают
// длиной в половину строки, а зондов до пятидесяти.
func writeProbes(b *strings.Builder, r *globalping.CheckResult) {
	if len(r.Probes) == 0 {
		return
	}
	fmt.Fprintf(b, "\n<b>Зонды (%d):</b>\n", len(r.Probes))

	head := b.String()
	lines := make([]string, 0, len(r.Probes))
	for _, p := range r.Probes {
		lines = append(lines, probeLine(p))
	}

	used := len([]rune(head))
	for i, line := range lines {
		rest := len(lines) - i
		tail := fmt.Sprintf("…и ещё %d зондов\n", rest)
		// Строка влезет только если после неё останется место на хвост про
		// оставшиеся — иначе обрежемся прямо сейчас и честно скажем сколько.
		if used+len([]rune(line))+len([]rune(tail)) > MessageLimit {
			b.WriteString(tail)
			return
		}
		b.WriteString(line)
		used += len([]rune(line))
	}
}

func probeLine(p globalping.ProbeDetail) string {
	mark := "❌"
	if p.TLSSuccess {
		mark = "✅"
	}

	place := p.City
	if place == "" {
		place = p.Country
	}
	if place == "" {
		place = "зонд"
	}

	provider := p.Network
	if provider == "" && p.ASN > 0 {
		provider = fmt.Sprintf("AS%d", p.ASN)
	}

	line := mark + " " + esc(place)
	if provider != "" {
		line += " · " + esc(provider)
	}
	if !p.TLSSuccess && p.Error != "" {
		line += " — " + esc(oneLine(p.Error))
	}
	return line + "\n"
}

// RenderStartReply — ответ на /start. Человеку нужен его chat_id, чтобы
// вписать его в панель: другого способа узнать этот номер у него нет.
func RenderStartReply(chatID int64, known bool) string {
	if known {
		return fmt.Sprintf("Бот на связи. Ваш ID: <code>%d</code>\n\n"+
			"Статус доступности приходит одним сообщением и обновляется сам "+
			"после каждой проверки.", chatID)
	}
	return fmt.Sprintf("Ваш ID: <code>%d</code>\n\n"+
		"Впишите его в панели: «Доступность из России» → «Телеграм-бот» → "+
		"ID админа, — и сохраните. После этого сюда придёт статус.", chatID)
}

// RenderTestMessage — то, что уходит по кнопке «Тест» в панели.
func RenderTestMessage(now time.Time) string {
	return "✅ <b>Бот подключён</b>\n\nПанель достучалась до Telegram в " +
		stamp(now) + ".\nСтатус доступности придёт отдельным сообщением."
}

// ── Мелочи ──────────────────────────────────────────────────────────────────

func levelDot(l globalping.Level) string {
	switch l {
	case globalping.LevelGreen:
		return dotGreen
	case globalping.LevelYellow:
		return dotYellow
	default:
		return dotRed
	}
}

// esc обязателен для всего, что пришло снаружи: имена провайдеров вида «AT&T»
// иначе ломают разметку, и Telegram отвечает 400 вместо сообщения.
func esc(s string) string { return html.EscapeString(s) }

func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.Join(strings.Fields(s), " ")
	if len([]rune(s)) > 80 {
		return string([]rune(s)[:80]) + "…"
	}
	return s
}

func stamp(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.Local().Format("02.01.2006, 15:04:05")
}

func humanInterval(d time.Duration) string {
	switch {
	case d <= 0:
		return "15 мин"
	case d < time.Hour:
		return fmt.Sprintf("%d мин", int(d.Minutes()))
	case d%time.Hour == 0:
		return fmt.Sprintf("%d ч", int(d.Hours()))
	default:
		return fmt.Sprintf("%d ч %d мин", int(d.Hours()), int(d.Minutes())%60)
	}
}

// duration печатает, сколько длится авария. Пустая строка — начала не знаем.
func duration(now, since time.Time) string {
	if since.IsZero() || now.IsZero() || !now.After(since) {
		return ""
	}
	d := now.Sub(since)
	switch {
	case d < time.Minute:
		return "меньше минуты"
	case d < time.Hour:
		return fmt.Sprintf("%d мин", int(d.Minutes()))
	default:
		return fmt.Sprintf("%d ч %d мин", int(d.Hours()), int(d.Minutes())%60)
	}
}
