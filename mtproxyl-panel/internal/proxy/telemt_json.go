package proxy

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// GetJSON запрашивает путь telemt API и декодирует поле data конверта в out.
func (p *TelemtProxy) GetJSON(ctx context.Context, path string, out any) error {
	req, err := p.newRequest(http.MethodGet, path, nil)
	if err != nil {
		return err
	}
	resp, err := p.client.Do(req.WithContext(ctx))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return decodeError(resp)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return err
	}
	var env struct {
		OK    bool            `json:"ok"`
		Data  json.RawMessage `json:"data"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return fmt.Errorf("telemt %s: invalid response: %w", path, err)
	}
	if !env.OK {
		code := env.Error.Code
		if code == "" {
			code = "api_error"
		}
		return &TelemtAPIError{Status: resp.StatusCode, Code: code, Message: env.Error.Message}
	}
	if out == nil || len(env.Data) == 0 {
		return nil
	}
	return json.Unmarshal(env.Data, out)
}
