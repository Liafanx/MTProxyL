package tgbot

import (
	"context"
	"log"
	"strings"
	"time"
)

// Команды бота. Регистрируются в Telegram, поэтому работают подсказки при
// наборе «/», и продублированы кнопками постоянной клавиатуры.
const (
	cmdStart  = "/start"
	cmdStatus = "/status"
	cmdCheck  = "/check"
	cmdMute   = "/mute"
	cmdUnmute = "/unmute"
	cmdHelp   = "/help"
)

// Подписи кнопок клавиатуры. Человеческие, а не голые команды: клавиатура
// делается для людей. Права всё равно проверяются, поэтому совпадение текста
// от постороннего ничего не даёт.
const (
	btnStatus = "📊 Статус"
	btnCheck  = "🔄 Проверить"
	btnMute   = "🔕 Пауза"
)

// callbackMute* — выбор длительности паузы.
const (
	callbackMute30 = "mute30"
	callbackMute2h = "mute2h"
	callbackMuteOn = "muteon"
)

// botCommands — то, что уходит в setMyCommands.
func botCommands() []BotCommand {
	return []BotCommand{
		{Command: "status", Description: "показать статус сейчас"},
		{Command: "check", Description: "запустить проверку доступности"},
		{Command: "mute", Description: "заглушить тревоги на время"},
		{Command: "unmute", Description: "снять паузу"},
		{Command: "help", Description: "что означают цифры"},
	}
}

// replyKeyboard — постоянная клавиатура под полем ввода.
func replyKeyboard() *ReplyKeyboardMarkup {
	return &ReplyKeyboardMarkup{
		Keyboard: [][]KeyboardButton{{
			{Text: btnStatus}, {Text: btnCheck}, {Text: btnMute},
		}},
		ResizeKeyboard: true,
		IsPersistent:   true,
	}
}

func muteKeyboard() *InlineKeyboardMarkup {
	return &InlineKeyboardMarkup{InlineKeyboard: [][]InlineKeyboardButton{{
		{Text: "30 минут", CallbackData: callbackMute30},
		{Text: "2 часа", CallbackData: callbackMute2h},
		{Text: "До отмены", CallbackData: callbackMuteOn},
	}}}
}

// normalizeCommand приводит нажатие кнопки клавиатуры к команде: кнопки шлют
// обычный текст, и разбирать его отдельно от команд незачем.
func normalizeCommand(text string) string {
	text = strings.TrimSpace(text)
	switch text {
	case btnStatus:
		return cmdStatus
	case btnCheck:
		return cmdCheck
	case btnMute:
		return cmdMute
	}
	if !strings.HasPrefix(text, "/") {
		return text
	}
	// «/status@my_bot» и «/status что-нибудь» — обычные формы, отсекаем хвост.
	// Только у команд: обычный текст трогать незачем.
	if i := strings.IndexAny(text, " @"); i > 0 {
		text = text[:i]
	}
	return strings.ToLower(text)
}

// registerCommands ставит подсказки команд. Сначала — в области конкретного
// чата, чтобы посторонний не видел даже списка. Но пока админ не нажал /start,
// чата не существует, и Telegram отвечает ошибкой: тогда ставим общий список,
// а на область чата перейдём после первого контакта.
func (b *Bot) registerCommands(ctx context.Context, client *Client, adminID int64) {
	if err := client.SetMyCommands(ctx, botCommands(), adminID); err == nil {
		return
	}
	if err := client.SetMyCommands(ctx, botCommands(), 0); err != nil {
		log.Printf("[tgbot] не удалось зарегистрировать команды: %s", err)
	}
}

// unregisterCommands снимает подсказки — при выключении бота или смене админа,
// чтобы список не остался висеть у прежнего владельца.
func (b *Bot) unregisterCommands(ctx context.Context, client *Client, adminID int64) {
	if client == nil {
		return
	}
	_ = client.DeleteMyCommands(ctx, adminID)
	_ = client.DeleteMyCommands(ctx, 0)
}

// handleCommand разбирает команду от админа.
func (b *Bot) handleCommand(ctx context.Context, client *Client, chatID int64, cmd string) {
	switch cmd {
	case cmdStart:
		b.replyStart(ctx, client, chatID)

	case cmdStatus:
		// Сообщение переезжает вниз чата — тихо, без звука. Иначе выходит
		// странность: человек попросил статус, статус обновился, но остался
		// висеть выше в истории, и выглядит это как «ничего не произошло».
		b.forceStatus()

	case cmdCheck:
		b.runCheckFromChat(ctx, client, chatID)

	case cmdMute:
		if _, err := client.SendMessage(ctx, chatID,
			"На сколько заглушить тревоги?\n\nСтатус всё это время продолжит обновляться тихо.",
			muteKeyboard(), true); err != nil {
			log.Printf("[tgbot] не удалось предложить паузу: %s", err)
		}

	case cmdUnmute:
		b.setMute(ctx, client, chatID, 0, false)

	case cmdHelp:
		if _, err := client.SendMessage(ctx, chatID, RenderHelp(), nil, true); err != nil {
			log.Printf("[tgbot] справка не ушла: %s", err)
		}
	}
}

// forceStatus просит перерисовать статус в обход ограничения частоты и
// переотправить его вниз чата.
func (b *Bot) forceStatus() {
	b.mu.Lock()
	b.forceRedraw = true
	b.mu.Unlock()
	b.requestRedraw()
}

// runCheckFromChat запускает настоящую проверку по команде.
func (b *Bot) runCheckFromChat(ctx context.Context, client *Client, chatID int64) {
	if b.deps.RunCheckNow == nil {
		_, _ = client.SendMessage(ctx, chatID, "Проверка доступности недоступна.", nil, true)
		return
	}
	// Кулдаун и исчерпанная квота отвечают мгновенно, настоящее измерение идёт
	// десятки секунд, — та же развилка, что у кнопки под сообщением.
	done := make(chan error, 1)
	go func() {
		_, err := b.deps.RunCheckNow(ctx)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			_, _ = client.SendMessage(ctx, chatID, "Проверка не запущена: "+esc(err.Error()), nil, true)
			return
		}
	case <-time.After(fastFailWindow):
		go func() {
			if err := <-done; err != nil {
				log.Printf("[tgbot] проверка по команде не удалась: %s", err)
			}
		}()
	}
	b.forceStatus()
}

// setMute включает или снимает паузу тревог.
//
// Снятие при живой аварии не может быть тихим: иначе человек снимает паузу и
// остаётся в уверенности, что всё хорошо, — а авария всё это время идёт.
func (b *Bot) setMute(ctx context.Context, client *Client, chatID int64, d time.Duration, forever bool) {
	now := b.now()

	b.mu.Lock()
	inc := b.state.Incidents
	switch {
	case forever:
		inc.MuteForever, inc.MutedUntil = true, time.Time{}
	case d > 0:
		inc.MuteForever, inc.MutedUntil = false, now.Add(d)
	default:
		inc.MuteForever, inc.MutedUntil = false, time.Time{}
	}
	b.state.Incidents = inc
	persist, state := b.deps.Persist, b.state
	b.mu.Unlock()

	if persist != nil {
		if err := persist(state); err != nil {
			log.Printf("[tgbot] не удалось сохранить паузу: %s", err)
		}
	}

	var text string
	switch {
	case forever:
		text = "🔕 Тревоги заглушены до отмены. Снять — /unmute"
	case d > 0:
		text = "🔕 Тревоги заглушены до " + inc.MutedUntil.Local().Format("15:04") + ". Снять — /unmute"
	case inc.AnyActive():
		text = "🔔 Пауза снята. Внимание: авария всё ещё продолжается — смотрите статус."
	default:
		text = "🔔 Пауза снята, тревоги снова включены."
	}
	if chatID != 0 {
		if _, err := client.SendMessage(ctx, chatID, text, nil, false); err != nil {
			log.Printf("[tgbot] не удалось сообщить о паузе: %s", err)
		}
	}
	b.forceStatus()
}
