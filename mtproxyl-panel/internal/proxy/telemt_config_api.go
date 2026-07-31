package proxy

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// telemtHTTPClient is shared so its connection pool is reused across calls
// (a fresh client per call would leak transports and skip keep-alive).
var telemtHTTPClient = &http.Client{Timeout: 15 * time.Second}

// TelemtAPIError carries a structured error returned by the Telemt API so
// callers (and ultimately the panel UI) can react to specific codes such as
// "revision_conflict".
type TelemtAPIError struct {
	Status  int
	Code    string
	Message string
}

func (e *TelemtAPIError) Error() string {
	return fmt.Sprintf("telemt api %d %s: %s", e.Status, e.Code, e.Message)
}

// PatchConfigResult mirrors Telemt's PATCH /v1/config `data` payload.
type PatchConfigResult struct {
	Revision        string   `json:"revision"`
	RestartRequired bool     `json:"restart_required"`
	Changed         []string `json:"changed"`
}

func (p *TelemtProxy) newRequest(method, path string, body io.Reader) (*http.Request, error) {
	req, err := http.NewRequest(method, p.targetURL+path, body)
	if err != nil {
		return nil, err
	}
	if p.authHeader != "" {
		req.Header.Set("Authorization", p.authHeader)
	}
	return req, nil
}

// decodeError reads a Telemt error envelope from a non-2xx response. When the
// body is not the expected JSON envelope (e.g. an upstream nginx/HTML error),
// the raw body is used as the message so the caller still gets a diagnostic.
func decodeError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var env struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &env)
	code := env.Error.Code
	if code == "" {
		code = "http_error"
	}
	msg := env.Error.Message
	if msg == "" {
		msg = strings.TrimSpace(string(body))
	}
	return &TelemtAPIError{Status: resp.StatusCode, Code: code, Message: msg}
}

// GetManagedConfig returns the editable config sections (as decoded JSON) and
// the current full-file revision from Telemt's GET /v1/config.
func (p *TelemtProxy) GetManagedConfig() (map[string]interface{}, string, error) {
	req, err := p.newRequest(http.MethodGet, "/v1/config", nil)
	if err != nil {
		return nil, "", err
	}
	resp, err := telemtHTTPClient.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, "", decodeError(resp)
	}
	var env struct {
		Data     map[string]interface{} `json:"data"`
		Revision string                 `json:"revision"`
	}
	// UseNumber so JSON integers (e.g. a port 443) decode as json.Number rather
	// than float64; otherwise they later render as 443.0 in the TOML editor.
	dec := json.NewDecoder(resp.Body)
	dec.UseNumber()
	if err := dec.Decode(&env); err != nil {
		return nil, "", err
	}
	if env.Data == nil {
		env.Data = map[string]interface{}{}
	}
	return env.Data, env.Revision, nil
}

// PatchManagedConfig applies a sparse patch (top-level keys must be editable
// sections) with optimistic concurrency via If-Match.
func (p *TelemtProxy) PatchManagedConfig(patch map[string]interface{}, ifMatch string) (*PatchConfigResult, error) {
	raw, err := json.Marshal(patch)
	if err != nil {
		return nil, err
	}
	req, err := p.newRequest(http.MethodPatch, "/v1/config", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if ifMatch != "" {
		req.Header.Set("If-Match", ifMatch)
	}
	resp, err := telemtHTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, decodeError(resp)
	}
	var env struct {
		Data PatchConfigResult `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return nil, err
	}
	return &env.Data, nil
}
