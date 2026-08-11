// Package tgbot зеркалит вердикт «Доступности из России» в личку админа в
// Telegram: одно живое сообщение, которое бот переписывает после каждой
// проверки, кнопки проверки прямо из чата и звуковой алерт при падении.
//
// Клиент Bot API написан на голом net/http намеренно: в панели семь прямых
// зависимостей, и весь внешний REST (Globalping, GitHub) сделан так же.
// Нужных методов шесть, библиотека ради них была бы единственным исключением.
package tgbot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const (
	// apiURL — публичный Bot API. Токен подставляется в путь.
	apiURL = "https://api.telegram.org"

	// callTimeout ограничивает обычный вызов. Отправка и правка сообщения
	// должны либо пройти быстро, либо не мешать следующей проверке.
	callTimeout = 15 * time.Second

	// pollTimeout — сколько Telegram держит getUpdates без событий. Клиент
	// обязан ждать дольше самого опроса, иначе каждый тихий период выглядел бы
	// сетевой ошибкой и запускал backoff на пустом месте.
	pollSeconds = 30
	pollTimeout = (pollSeconds + 15) * time.Second

	// MessageLimit — предел длины сообщения в Telegram.
	MessageLimit = 4096
)

// APIError — отказ, о котором Telegram сказал в конверте ответа. Отдельный тип
// нужен потому, что половина отказов здесь — штатные ситуации, а не поломки:
// «текст не изменился» при повторной отрисовке того же вердикта, «сообщения
// больше нет» после ручного удаления в чате.
type APIError struct {
	Method      string
	Code        int
	Description string
	RetryAfter  time.Duration
}

func (e *APIError) Error() string {
	if e.RetryAfter > 0 {
		return fmt.Sprintf("%s: %d %s (повтор через %s)", e.Method, e.Code, e.Description, e.RetryAfter)
	}
	return fmt.Sprintf("%s: %d %s", e.Method, e.Code, e.Description)
}

// IsNotModified — правка не изменила текст. Это норма: вердикт мог повториться
// один в один, и писать о таком в лог значит засорять его каждые 15 минут.
func (e *APIError) IsNotModified() bool {
	return strings.Contains(strings.ToLower(e.Description), "message is not modified")
}

// IsMessageGone — сообщения, которое мы правим или удаляем, уже нет: его убрали
// руками или оно старше 48 часов. Лечится отправкой нового.
func (e *APIError) IsMessageGone() bool {
	d := strings.ToLower(e.Description)
	switch {
	case strings.Contains(d, "message to edit not found"),
		strings.Contains(d, "message to delete not found"),
		strings.Contains(d, "message can't be edited"),
		strings.Contains(d, "message can't be deleted"),
		strings.Contains(d, "message identifier is not specified"):
		return true
	}
	return false
}

// IsUnauthorized — токен неверный или отозван. Опрос продолжать бессмысленно.
func (e *APIError) IsUnauthorized() bool { return e.Code == http.StatusUnauthorized }

// IsConflict — этим же токеном getUpdates делает кто-то ещё. Telegram не даёт
// двум потребителям читать обновления одного бота.
func (e *APIError) IsConflict() bool { return e.Code == http.StatusConflict }

// IsChatNotFound — админ ещё не открывал диалог с ботом. Telegram не позволяет
// боту написать первым, пока человек не нажал /start.
func (e *APIError) IsChatNotFound() bool {
	d := strings.ToLower(e.Description)
	return strings.Contains(d, "chat not found") || strings.Contains(d, "bot can't initiate conversation")
}

// asAPIError достаёт *APIError из цепочки, если он там есть.
func asAPIError(err error) (*APIError, bool) {
	var e *APIError
	if errors.As(err, &e) {
		return e, true
	}
	return nil, false
}

// Client — минимальный клиент Bot API.
type Client struct {
	token   string
	baseURL string
	http    *http.Client
	poll    *http.Client
}

func NewClient(token string) *Client {
	return &Client{
		token:   token,
		baseURL: apiURL,
		http:    &http.Client{Timeout: callTimeout},
		poll:    &http.Client{Timeout: pollTimeout},
	}
}

// ── Типы Bot API, ограниченные тем, что мы читаем ───────────────────────────

type User struct {
	ID       int64  `json:"id"`
	IsBot    bool   `json:"is_bot"`
	Username string `json:"username"`
}

type Chat struct {
	ID int64 `json:"id"`
}

type Message struct {
	MessageID int    `json:"message_id"`
	Chat      Chat   `json:"chat"`
	Text      string `json:"text"`
	From      *User  `json:"from"`
}

type CallbackQuery struct {
	ID      string   `json:"id"`
	From    User     `json:"from"`
	Message *Message `json:"message"`
	Data    string   `json:"data"`
}

type Update struct {
	UpdateID      int            `json:"update_id"`
	Message       *Message       `json:"message"`
	CallbackQuery *CallbackQuery `json:"callback_query"`
}

// InlineKeyboardButton — кнопка под сообщением.
type InlineKeyboardButton struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data"`
}

// InlineKeyboardMarkup — ряды кнопок.
type InlineKeyboardMarkup struct {
	InlineKeyboard [][]InlineKeyboardButton `json:"inline_keyboard"`
}

// ── Вызовы ──────────────────────────────────────────────────────────────────

// GetMe проверяет токен и заодно узнаёт имя бота для панели.
func (c *Client) GetMe(ctx context.Context) (*User, error) {
	var out User
	if err := c.call(ctx, c.http, "getMe", nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// SendMessage отправляет новое сообщение и возвращает его — нужен message_id,
// чтобы дальше править именно его.
func (c *Client) SendMessage(ctx context.Context, chatID int64, text string, kb *InlineKeyboardMarkup, silent bool) (*Message, error) {
	req := map[string]any{
		"chat_id":                  chatID,
		"text":                     text,
		"parse_mode":               "HTML",
		"disable_web_page_preview": true,
		"disable_notification":     silent,
	}
	if kb != nil {
		req["reply_markup"] = kb
	}
	var out Message
	if err := c.call(ctx, c.http, "sendMessage", req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// EditMessageText переписывает уже отправленное сообщение. Звука не даёт —
// именно поэтому событиям нужна отправка нового, а не правка.
func (c *Client) EditMessageText(ctx context.Context, chatID int64, messageID int, text string, kb *InlineKeyboardMarkup) error {
	req := map[string]any{
		"chat_id":                  chatID,
		"message_id":               messageID,
		"text":                     text,
		"parse_mode":               "HTML",
		"disable_web_page_preview": true,
	}
	if kb != nil {
		req["reply_markup"] = kb
	}
	return c.call(ctx, c.http, "editMessageText", req, nil)
}

// DeleteMessage убирает прежнее живое сообщение. Telegram не даёт удалять свои
// сообщения старше 48 часов — вызывающий обязан пережить отказ.
func (c *Client) DeleteMessage(ctx context.Context, chatID int64, messageID int) error {
	return c.call(ctx, c.http, "deleteMessage", map[string]any{
		"chat_id":    chatID,
		"message_id": messageID,
	}, nil)
}

// AnswerCallbackQuery гасит «часики» на кнопке. show_alert=true показывает
// всплывающее окно — им объясняем отказ по кулдауну.
func (c *Client) AnswerCallbackQuery(ctx context.Context, id, text string, alert bool) error {
	req := map[string]any{"callback_query_id": id}
	if text != "" {
		req["text"] = text
		req["show_alert"] = alert
	}
	return c.call(ctx, c.http, "answerCallbackQuery", req, nil)
}

// GetUpdates — длинный опрос. offset подтверждает всё, что уже разобрано:
// Telegram не отдаст эти обновления снова.
func (c *Client) GetUpdates(ctx context.Context, offset int) ([]Update, error) {
	req := map[string]any{
		"offset":          offset,
		"timeout":         pollSeconds,
		"allowed_updates": []string{"message", "callback_query"},
	}
	var out []Update
	if err := c.call(ctx, c.poll, "getUpdates", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ── Транспорт ───────────────────────────────────────────────────────────────

// apiEnvelope — общий конверт всех ответов Bot API.
type apiEnvelope struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	ErrorCode   int             `json:"error_code"`
	Description string          `json:"description"`
	Parameters  *struct {
		RetryAfter int `json:"retry_after"`
	} `json:"parameters"`
}

func (c *Client) call(ctx context.Context, hc *http.Client, method string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("%s: сборка запроса: %w", method, err)
		}
		reader = bytes.NewReader(raw)
	}

	url := fmt.Sprintf("%s/bot%s/%s", c.baseURL, c.token, method)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := hc.Do(req)
	if err != nil {
		// Токен в URL: он не должен попасть ни в лог, ни в интерфейс панели.
		return fmt.Errorf("%s: Telegram не отвечает: %w", method, redactToken(err, c.token))
	}
	defer func() { _ = resp.Body.Close() }()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("%s: чтение ответа: %w", method, err)
	}

	var env apiEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		// Не JSON — обычно это страница прокси или капчи между нами и API.
		return &APIError{Method: method, Code: resp.StatusCode, Description: snippet(raw)}
	}
	if !env.OK {
		apiErr := &APIError{Method: method, Code: env.ErrorCode, Description: env.Description}
		if apiErr.Code == 0 {
			apiErr.Code = resp.StatusCode
		}
		if env.Parameters != nil && env.Parameters.RetryAfter > 0 {
			apiErr.RetryAfter = time.Duration(env.Parameters.RetryAfter) * time.Second
		}
		return apiErr
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(env.Result, out); err != nil {
		return fmt.Errorf("%s: разбор ответа: %w", method, err)
	}
	return nil
}

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		return s[:200] + "…"
	}
	if s == "" {
		return "пустой ответ"
	}
	return s
}

// redactToken прячет токен в тексте ошибки: net/http вкладывает в неё полный
// URL, а он содержит секрет.
func redactToken(err error, token string) error {
	if token == "" {
		return err
	}
	msg := strings.ReplaceAll(err.Error(), token, "<токен>")
	return fmt.Errorf("%s", msg)
}
