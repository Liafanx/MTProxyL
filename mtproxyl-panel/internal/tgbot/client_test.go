package tgbot

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// newFakeAPI поднимает подставной Bot API. Обработчик получает имя метода —
// последний сегмент пути, — чтобы тест отвечал по-разному на разные вызовы.
func newFakeAPI(t *testing.T, handler func(method string, w http.ResponseWriter, r *http.Request)) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		w.Header().Set("Content-Type", "application/json")
		handler(parts[len(parts)-1], w, r)
	}))
	t.Cleanup(srv.Close)

	c := NewClient("123456:test-token")
	c.baseURL = srv.URL
	return c
}

func okResult(w http.ResponseWriter, result any) {
	raw, _ := json.Marshal(result)
	_, _ = w.Write([]byte(`{"ok":true,"result":` + string(raw) + `}`))
}

func apiFailure(w http.ResponseWriter, code int, description string) {
	w.WriteHeader(code)
	_, _ = w.Write([]byte(`{"ok":false,"error_code":` + strconv.Itoa(code) + `,"description":"` + description + `"}`))
}

func TestGetMeReturnsBotIdentity(t *testing.T) {
	c := newFakeAPI(t, func(method string, w http.ResponseWriter, r *http.Request) {
		if method != "getMe" {
			t.Errorf("вызван %q, ожидался getMe", method)
		}
		okResult(w, User{ID: 42, IsBot: true, Username: "mtproxyl_watch_bot"})
	})

	me, err := c.GetMe(context.Background())
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if me.Username != "mtproxyl_watch_bot" {
		t.Errorf("Username = %q", me.Username)
	}
}

func TestSendMessageReturnsMessageID(t *testing.T) {
	var got map[string]any
	c := newFakeAPI(t, func(_ string, w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		okResult(w, Message{MessageID: 77, Chat: Chat{ID: 555}})
	})

	msg, err := c.SendMessage(context.Background(), 555, "текст", &InlineKeyboardMarkup{
		InlineKeyboard: [][]InlineKeyboardButton{{{Text: "Обновить", CallbackData: "refresh"}}},
	}, false)
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if msg.MessageID != 77 {
		t.Errorf("MessageID = %d, want 77", msg.MessageID)
	}
	if got["parse_mode"] != "HTML" {
		t.Errorf("parse_mode = %v, ожидался HTML", got["parse_mode"])
	}
	if got["reply_markup"] == nil {
		t.Error("клавиатура не ушла в запросе")
	}
}

// «Текст не изменился» — штатный ответ на повторную отрисовку того же вердикта,
// а не поломка: вызывающий обязан отличать его от настоящей ошибки.
func TestEditMessageNotModifiedIsRecognisable(t *testing.T) {
	c := newFakeAPI(t, func(_ string, w http.ResponseWriter, _ *http.Request) {
		apiFailure(w, 400, "Bad Request: message is not modified")
	})

	err := c.EditMessageText(context.Background(), 555, 77, "тот же текст", nil)
	apiErr, ok := asAPIError(err)
	if !ok {
		t.Fatalf("ожидалась *APIError, получено: %v", err)
	}
	if !apiErr.IsNotModified() {
		t.Errorf("IsNotModified() = false для %q", apiErr.Description)
	}
	if apiErr.IsMessageGone() {
		t.Error("IsMessageGone() = true — это другой случай")
	}
}

func TestMessageGoneVariants(t *testing.T) {
	cases := []struct {
		description string
		gone        bool
	}{
		{"Bad Request: message to edit not found", true},
		{"Bad Request: message to delete not found", true},
		{"Bad Request: message can't be edited", true},
		{"Bad Request: message is not modified", false},
		{"Bad Request: chat not found", false},
	}
	for _, tc := range cases {
		t.Run(tc.description, func(t *testing.T) {
			e := &APIError{Description: tc.description}
			if got := e.IsMessageGone(); got != tc.gone {
				t.Errorf("IsMessageGone() = %v, want %v", got, tc.gone)
			}
		})
	}
}

// 429 приходит с retry_after: ждать надо ровно столько, сколько сказал сервис.
func TestRateLimitCarriesRetryAfter(t *testing.T) {
	c := newFakeAPI(t, func(_ string, w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}`))
	})

	err := c.EditMessageText(context.Background(), 1, 2, "текст", nil)
	apiErr, ok := asAPIError(err)
	if !ok {
		t.Fatalf("ожидалась *APIError, получено: %v", err)
	}
	if apiErr.RetryAfter != 7*time.Second {
		t.Errorf("RetryAfter = %v, want 7s", apiErr.RetryAfter)
	}
}

func TestUnauthorizedAndConflictAreDistinguished(t *testing.T) {
	unauthorized := &APIError{Code: http.StatusUnauthorized, Description: "Unauthorized"}
	if !unauthorized.IsUnauthorized() || unauthorized.IsConflict() {
		t.Error("401 должен распознаваться как неверный токен")
	}
	conflict := &APIError{Code: http.StatusConflict, Description: "terminated by other getUpdates request"}
	if !conflict.IsConflict() || conflict.IsUnauthorized() {
		t.Error("409 должен распознаваться как второй опрашивающий")
	}
}

// Админ не нажимал /start — бот не имеет права написать первым, и это надо
// объяснить человеку, а не показывать голый код ошибки.
func TestChatNotFoundIsRecognisable(t *testing.T) {
	e := &APIError{Code: 400, Description: "Bad Request: chat not found"}
	if !e.IsChatNotFound() {
		t.Error("IsChatNotFound() = false")
	}
}

// Между панелью и Telegram может стоять прокси, отдающий HTML. Это не JSON,
// и клиент обязан сказать что-то внятное, а не упасть на разборе.
func TestNonJSONResponseBecomesAPIError(t *testing.T) {
	c := newFakeAPI(t, func(_ string, w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("<html>502 Bad Gateway</html>"))
	})

	_, err := c.GetMe(context.Background())
	apiErr, ok := asAPIError(err)
	if !ok {
		t.Fatalf("ожидалась *APIError, получено: %v", err)
	}
	if apiErr.Code != http.StatusBadGateway {
		t.Errorf("Code = %d, want 502", apiErr.Code)
	}
}

func TestGetUpdatesPassesOffset(t *testing.T) {
	var got map[string]any
	c := newFakeAPI(t, func(_ string, w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		okResult(w, []Update{{UpdateID: 10, Message: &Message{Text: "/start", Chat: Chat{ID: 5}}}})
	})

	updates, err := c.GetUpdates(context.Background(), 9)
	if err != nil {
		t.Fatalf("GetUpdates: %v", err)
	}
	if len(updates) != 1 || updates[0].UpdateID != 10 {
		t.Fatalf("updates = %+v", updates)
	}
	if got["offset"] != float64(9) {
		t.Errorf("offset = %v, want 9", got["offset"])
	}
}

// Токен лежит в URL, поэтому сетевая ошибка от net/http несёт его в тексте.
// Наружу он уйти не должен: эта строка попадает и в лог, и в панель.
func TestNetworkErrorHidesToken(t *testing.T) {
	c := NewClient("123456:very-secret-token")
	c.baseURL = "http://127.0.0.1:1" // никто не слушает
	c.http = &http.Client{Timeout: 200 * time.Millisecond}

	_, err := c.GetMe(context.Background())
	if err == nil {
		t.Fatal("ожидалась сетевая ошибка")
	}
	if strings.Contains(err.Error(), "very-secret-token") {
		t.Errorf("токен утёк в текст ошибки: %s", err)
	}
}
