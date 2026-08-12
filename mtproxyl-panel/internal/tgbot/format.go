package tgbot

import (
	"fmt"
	"html"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
	"github.com/Liafanx/mtproxyl-panel/internal/uplink"
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
	// BannerEngineDown — движок недоступен или ушёл в режим только чтения.
	BannerEngineDown
	// BannerEngineOK — движок вернулся.
	BannerEngineOK
	// BannerUplinkDown — прокси потерял связь с дата-центрами Telegram.
	BannerUplinkDown
	// BannerUplinkOK — связь с дата-центрами восстановлена.
	BannerUplinkOK
	// BannerEngineRestarted и BannerIPChanged — одноразовые: у них нет
	// «восстановления», о них просто сообщают один раз.
	BannerEngineRestarted
	BannerIPChanged
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
	// AvailabilityEnabled=false — внешняя проверка выключена в конфиге панели.
	// Тогда о ней пишется одна строка, а не «проверок ещё не было»: ждать
	// нечего, и обещать первую проверку было бы неправдой.
	AvailabilityEnabled bool

	// Uplink — состояние исходящей связи и движка. nil, если наблюдение ещё не
	// дало первого результата.
	Uplink *uplink.Status

	// Banners — шапки события. Их может быть несколько: доступность и связь
	// независимы и могут сорваться одновременно, но сообщение всё равно одно.
	Banners []Banner
	// PrevPercentage — доступность до события, для строки «было X% → стало Y%».
	// PrevKnown отличает «раньше было 0%» от «раньше ничего не было».
	PrevPercentage float64
	PrevKnown      bool
	// AlertSince — когда началась авария доступности, для «длится N».
	AlertSince time.Time
	// UplinkSince и EngineSince — то же для двух других аварий.
	UplinkSince time.Time
	EngineSince time.Time
	// PrevIP и NewIP заполняются, когда сменился внешний адрес сервера.
	PrevIP, NewIP string

	// MutedUntil и MuteForever — пауза тревог. Пока она идёт, в шапке висит
	// напоминание: иначе легко забыть, что сирена выключена.
	MutedUntil  time.Time
	MuteForever bool

	Threshold float64
	Now       time.Time
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

	writeBanners(&b, v)

	if v.Failure != nil {
		b.WriteString("⚠️ <b>Проверка не удалась</b>\n")
		b.WriteString(esc(v.Failure.Reason) + "\n")
		b.WriteString("Попытка: " + stamp(v.Failure.At) + "\n")
		if v.Result == nil {
			b.WriteString("\nУдачных проверок пока не было.\n")
			writeFooter(&b, v)
			// Блок связи нужен и здесь: он наблюдается раз в минуту и не зависит
			// от того, успела ли пройти проверка доступности.
			writeUplink(&b, v)
			return clamp(b.String())
		}
		b.WriteString("\nНиже — последний известный вердикт.\n\n")
	}

	if v.Result == nil {
		if !v.AvailabilityEnabled {
			b.WriteString("<b>Доступность из РФ</b>: проверка выключена в конфиге панели.\n")
		} else {
			b.WriteString("Проверок ещё не было — первая пройдёт в ближайшие минуты.\n")
		}
		writeFooter(&b, v)
		// Первые четверть часа после запуска вердикта доступности ещё нет, а
		// связь с дата-центрами уже наблюдается — показываем то, что знаем.
		writeUplink(&b, v)
		return clamp(b.String())
	}

	r := v.Result
	fmt.Fprintf(&b, "%s <b>Доступность из РФ — %.0f%%</b>\n\n", levelDot(r.Level), r.Percentage)
	fmt.Fprintf(&b, "Зондов: <b>%d / %d</b>\n", r.SuccessProbes, r.TotalProbes)

	writeTarget(&b, v)
	b.WriteString("Проверено: " + stamp(r.CheckedAt) + "\n")
	writeFooter(&b, v)

	writeUplink(&b, v)
	// Зонды — последними: их обрезка считает уже занятое место, поэтому блок
	// связи, поставленный сюда, влезает всегда, а ужимается список зондов. Если
	// поменять местами, при полусотне зондов блок связи просто не поместится —
	// то есть пропадёт ровно тогда, когда он нужнее всего.
	writeProbes(&b, r)
	return clamp(b.String())
}

// writeUplink — второй блок сообщения: исходящая связь прокси с
// дата-центрами Telegram. Отвечает на вопрос, которого не видит проверка
// зондами: снаружи прокси может быть здоров, а писать в Telegram не может.
func writeUplink(b *strings.Builder, v View) {
	u := v.Uplink
	if u == nil {
		return
	}

	b.WriteString("\n──────────\n\n")

	switch {
	case u.EngineError != "":
		b.WriteString("⚠️ <b>Связь с Telegram — нет данных</b>\n")
		b.WriteString(esc(u.EngineError) + "\n")
		return
	case !u.Applicable:
		// Не авария: часть установок работает без middle proxy. Формулировка та
		// же, что в панели, чтобы бот и интерфейс говорили одно и то же.
		b.WriteString("<b>Связь с Telegram</b>: данные недоступны — " + esc(u.NotApplicableReason) + "\n")
		return
	}

	fmt.Fprintf(b, "%s <b>Связь с Telegram — %s</b>\n", levelDot(globalpingLevel(u.Level)), uplinkVerdict(u))
	b.WriteString("<i>выход: прокси → дата-центры</i>\n\n")

	// Причины идут отдельными строками, а не в заголовке: там они складывались
	// в неразборчивую строку с двойным тире.
	for _, p := range u.Problems {
		b.WriteString("⚠️ " + esc(p) + "\n")
	}
	fmt.Fprintf(b, "Писатели: <b>%d</b> живых / %d нужно\n", u.AliveWriters, u.RequiredWriters)
	if u.HasFailRate && u.Attempts > 0 {
		fmt.Fprintf(b, "Ошибок подключения: %.1f%% (%d из %d)\n", u.FailRate*100, u.Fails, u.Attempts)
	}
	writeDCs(b, u.DCs)
	if u.Version != "" {
		fmt.Fprintf(b, "Движок: %s, работает %s\n", esc(u.Version),
			duration(v.Now, v.Now.Add(-time.Duration(u.UptimeSeconds)*time.Second)))
	}
	b.WriteString("Проверено: " + stampShort(u.CheckedAt) + "\n")
}

func uplinkVerdict(u *uplink.Status) string {
	switch {
	case len(u.Problems) == 0:
		return "норма"
	case u.AliveWriters == 0:
		return "связи нет"
	default:
		return "с перебоями"
	}
}

// globalpingLevel переводит уровень наблюдателя в тот же светофор, которым
// обозначается доступность, — чтобы в одном сообщении цвета читались одинаково.
func globalpingLevel(l uplink.Level) globalping.Level {
	switch l {
	case uplink.LevelGreen:
		return globalping.LevelGreen
	case uplink.LevelYellow:
		return globalping.LevelYellow
	default:
		return globalping.LevelRed
	}
}

// writeDCs печатает дата-центры по два в строке. Показываем все, включая те,
// где писателей нет: на живом сервере это штатно, и человеку полезно видеть
// картину целиком — но решение об аварии по ним не принимается.
func writeDCs(b *strings.Builder, dcs []uplink.DCRtt) {
	if len(dcs) == 0 {
		return
	}
	b.WriteString("\n")
	for i, dc := range dcs {
		mark := "✅"
		if dc.AliveWriters == 0 {
			mark = "⚪"
		}
		rtt := "—"
		if dc.RTTEmaMs != nil {
			rtt = fmt.Sprintf("%.0f мс", *dc.RTTEmaMs)
		}
		fmt.Fprintf(b, "%s DC %d: %s", mark, dc.DC, rtt)
		if i%2 == 1 || i == len(dcs)-1 {
			b.WriteString("\n")
		} else {
			b.WriteString("   ")
		}
	}
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

// writeBanners печатает шапки событий. Порядок — по важности: упавший движок
// объясняет всё остальное, поэтому идёт первым.
func writeBanners(b *strings.Builder, v View) {
	wrote := false
	for _, banner := range v.Banners {
		if banner == BannerNone {
			continue
		}
		writeBanner(b, v, banner)
		wrote = true
	}
	if muted := muteNote(v); muted != "" {
		b.WriteString(muted)
		wrote = true
	}
	if wrote {
		b.WriteString("\n──────────\n\n")
	}
}

func writeBanner(b *strings.Builder, v View, banner Banner) {
	switch banner {
	case BannerDown:
		b.WriteString("🚨 <b>ПАДЕНИЕ ДОСТУПНОСТИ</b>\n")
		writeChange(b, v)
		if since := duration(v.Now, v.AlertSince); since != "" {
			fmt.Fprintf(b, "Длится %s · порог %.0f%%\n", since, v.Threshold)
		} else {
			fmt.Fprintf(b, "Порог алерта: %.0f%%\n", v.Threshold)
		}
		b.WriteString("Часто это значит, что адрес попал под фильтр у части операторов.\n")

	case BannerRecovered:
		b.WriteString("✅ <b>ДОСТУПНОСТЬ ВОССТАНОВЛЕНА</b>\n")
		writeChange(b, v)
		if since := duration(v.Now, v.AlertSince); since != "" {
			b.WriteString("Авария длилась " + since + "\n")
		}

	case BannerUplinkDown:
		b.WriteString("🚨 <b>ПРОКСИ ПОТЕРЯЛ СВЯЗЬ С TELEGRAM</b>\n")
		if v.Uplink != nil {
			for _, p := range v.Uplink.Problems {
				b.WriteString(esc(p) + "\n")
			}
		}
		if since := duration(v.Now, v.UplinkSince); since != "" {
			b.WriteString("Длится " + since + "\n")
		}
		// Это принципиально другая авария, чем падение доступности, и человеку
		// надо сразу понимать разницу: снаружи прокси при этом здоров.
		b.WriteString("Снаружи прокси доступен — режут выход к дата-центрам, а не вход к прокси.\n")

	case BannerUplinkOK:
		b.WriteString("✅ <b>СВЯЗЬ С TELEGRAM ВОССТАНОВЛЕНА</b>\n")
		if since := duration(v.Now, v.UplinkSince); since != "" {
			b.WriteString("Авария длилась " + since + "\n")
		}

	case BannerEngineDown:
		b.WriteString("🚨 <b>ДВИЖОК НЕДОСТУПЕН</b>\n")
		if v.Uplink != nil {
			switch {
			case v.Uplink.EngineReadOnly:
				b.WriteString("Движок работает в режиме только чтения.\n")
			case v.Uplink.EngineError != "":
				b.WriteString(esc(v.Uplink.EngineError) + "\n")
			}
		}
		if since := duration(v.Now, v.EngineSince); since != "" {
			b.WriteString("Длится " + since + "\n")
		}

	case BannerEngineOK:
		b.WriteString("✅ <b>ДВИЖОК СНОВА НА СВЯЗИ</b>\n")
		if since := duration(v.Now, v.EngineSince); since != "" {
			b.WriteString("Недоступен был " + since + "\n")
		}

	case BannerEngineRestarted:
		b.WriteString("♻️ <b>Движок перезапустился</b>\n")
		if v.Uplink != nil && v.Uplink.UptimeSeconds > 0 {
			b.WriteString("Работает " + duration(v.Now, v.Now.Add(-time.Duration(v.Uplink.UptimeSeconds)*time.Second)) + "\n")
		}

	case BannerIPChanged:
		b.WriteString("📍 <b>Сменился внешний адрес сервера</b>\n")
		fmt.Fprintf(b, "Было <code>%s</code> → стало <code>%s</code>\n", esc(v.PrevIP), esc(v.NewIP))
		b.WriteString("Проверьте DNS и ссылки для клиентов — прежний адрес больше не отвечает.\n")
	}
}

// muteNote напоминает о выключенной сирене. Без этой строки легко поставить
// паузу на время работ и забыть о ней до следующей настоящей аварии.
func muteNote(v View) string {
	switch {
	case v.MuteForever:
		return "🔕 <b>Тревоги заглушены до отмены</b> — /unmute\n"
	case !v.MutedUntil.IsZero() && v.Now.Before(v.MutedUntil):
		return "🔕 <b>Тревоги заглушены до " + v.MutedUntil.Local().Format("15:04") + "</b> — /unmute\n"
	}
	return ""
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
	if !v.AvailabilityEnabled {
		// Строка про автопроверку без самой проверки только запутала бы.
		return
	}
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

// RenderHelp объясняет, что означают цифры. Главное здесь — разница между
// двумя блоками: она неочевидна, а именно она и объясняет, почему прокси
// может быть «доступен» и при этом не работать.
func RenderHelp() string {
	return "<b>Что показывает бот</b>\n\n" +
		"<b>Доступность из РФ</b> — вход: видят ли вас клиенты. Зонды из российских " +
		"резидентских сетей делают TLS-рукопожатие с портом прокси. Падение обычно значит, " +
		"что адрес попал под фильтр у части операторов.\n\n" +
		"<b>Связь с Telegram</b> — выход: может ли прокси писать в дата-центры. Фильтрация " +
		"часто режет именно это: снаружи сервер доступен, зонды показывают 95%, а клиенты " +
		"не работают.\n\n" +
		"<b>Писатели</b> — соединения, через которые движок пишет в Telegram. Если живых " +
		"меньше, чем нужно, трафик идёт хуже; если ноль — связи нет вовсе.\n\n" +
		"Дата-центры показаны для полноты: у части из них писателей штатно нет, и само по " +
		"себе это не авария — поэтому тревога поднимается по общему счёту, а не по ним.\n\n" +
		"<b>Команды</b>\n" +
		"/status — показать статус сейчас\n" +
		"/check — запустить проверку (тратит квоту)\n" +
		"/mute — заглушить тревоги на время работ\n" +
		"/unmute — снять паузу"
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

// stampShort — время без секунд. Блок связи обновляется раз в минуту, и
// секунды в нём ничего не добавляют.
// plural выбирает форму слова: «1 день», «2 дня», «5 дней».
func plural(n int, one, few, many string) string {
	n %= 100
	if n >= 11 && n <= 14 {
		return many
	}
	switch n % 10 {
	case 1:
		return one
	case 2, 3, 4:
		return few
	default:
		return many
	}
}

func stampShort(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.Local().Format("02.01.2006, 15:04")
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
	case d < 24*time.Hour:
		return fmt.Sprintf("%d ч %d мин", int(d.Hours()), int(d.Minutes())%60)
	default:
		days := int(d.Hours()) / 24
		return fmt.Sprintf("%d %s %d ч", days, plural(days, "день", "дня", "дней"), int(d.Hours())%24)
	}
}
