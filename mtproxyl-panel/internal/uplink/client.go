package uplink

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// httpTimeout ограничивает один запрос к движку. Заведомо меньше интервала
// опроса: зависшее соединение не должно наложиться на следующий тик.
//
// Отдельный клиент, а не http.DefaultClient (которым ходит
// proxy.GetSystemInfo): у того таймаута нет вовсе, и для фонового тикера это
// означало бы горутину, повисшую навсегда, — мониторинг тихо умер бы,
// продолжая показывать последние удачные цифры.
const httpTimeout = 10 * time.Second

// APIError — движок ответил, но отказом. Отдельно от сетевой ошибки, потому
// что читается по-разному: «нет связи с движком» и «движок не дал данные» —
// разные вещи для того, кто потом читает сообщение.
type APIError struct {
	Endpoint string
	Status   int
	Code     string
	Message  string
}

func (e *APIError) Error() string {
	switch {
	case e.Code != "" && e.Message != "":
		return fmt.Sprintf("%s: %s: %s", e.Endpoint, e.Code, e.Message)
	case e.Message != "":
		return fmt.Sprintf("%s: %s", e.Endpoint, e.Message)
	case e.Code != "":
		return fmt.Sprintf("%s: %s", e.Endpoint, e.Code)
	default:
		return fmt.Sprintf("%s: движок ответил %d", e.Endpoint, e.Status)
	}
}

// Client ходит в API движка telemt. Адрес и заголовок авторизации — те же, что
// у ws.Handler (см. server.go, где он собирается из config.TelemtConfig).
type Client struct {
	baseURL    string
	authHeader string
	http       *http.Client
}

func NewClient(baseURL, authHeader string) *Client {
	return &Client{
		baseURL:    strings.TrimSuffix(baseURL, "/"),
		authHeader: authHeader,
		http:       &http.Client{Timeout: httpTimeout},
	}
}

// get забирает эндпоинт и разбирает общий конверт telemt.
//
// Здесь легко ошибиться, и ошибка дорогая: `ok:false` в конверте — это «не
// смогли узнать» (движок лежит, сеть, авторизация), а `enabled:false` ВНУТРИ
// data — это «функция выключена в конфиге движка». Первое надо показывать как
// сбой, второе — как «не применимо». Смешать их значит объявить «middle proxy
// отключили» при обычном обрыве связи с движком.
func (c *Client) get(ctx context.Context, endpoint string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if c.authHeader != "" {
		req.Header.Set("Authorization", c.authHeader)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		// Самая частая причина — движок перезапускается: несколько секунд он
		// не отвечает. Формулировка та же, что в ws-обработчике, чтобы панель
		// и бот объясняли одно и то же одинаково.
		return fmt.Errorf("движок telemt не отвечает: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return fmt.Errorf("%s: чтение ответа: %w", endpoint, err)
	}

	var envelope struct {
		OK   bool            `json:"ok"`
		Data json.RawMessage `json:"data"`
		Err  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return &APIError{Endpoint: endpoint, Status: resp.StatusCode, Message: "ответ не разобран"}
	}
	if !envelope.OK {
		apiErr := &APIError{Endpoint: endpoint, Status: resp.StatusCode}
		if envelope.Err != nil {
			apiErr.Code, apiErr.Message = envelope.Err.Code, envelope.Err.Message
		}
		return apiErr
	}
	if out == nil {
		return nil
	}
	if len(envelope.Data) == 0 {
		return &APIError{Endpoint: endpoint, Status: resp.StatusCode, Message: "пустой ответ"}
	}
	if err := json.Unmarshal(envelope.Data, out); err != nil {
		return fmt.Errorf("%s: разбор данных: %w", endpoint, err)
	}
	return nil
}

func (c *Client) MeQuality(ctx context.Context) (*MeQuality, error) {
	var out MeQuality
	if err := c.get(ctx, "/v1/runtime/me_quality", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) UpstreamQuality(ctx context.Context) (*UpstreamQuality, error) {
	var out UpstreamQuality
	if err := c.get(ctx, "/v1/runtime/upstream_quality", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) Health(ctx context.Context) (*Health, error) {
	var out Health
	if err := c.get(ctx, "/v1/health", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) SystemInfo(ctx context.Context) (*SystemInfo, error) {
	var out SystemInfo
	if err := c.get(ctx, "/v1/system/info", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) Summary(ctx context.Context) (*Summary, error) {
	var out Summary
	if err := c.get(ctx, "/v1/stats/summary", &out); err != nil {
		return nil, err
	}
	return &out, nil
}
