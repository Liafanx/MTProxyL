package globalping

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	// APIURL is Globalping's public API. No account is required.
	APIURL = "https://api.globalping.io/v1"
	// httpTimeout bounds a single API call, not the whole measurement.
	httpTimeout = 30 * time.Second

	// eyeballTag selects probes on residential ISP networks. Filtering is
	// applied to subscriber traffic, so a probe in a data centre can happily
	// reach a server that no home user in the country can.
	eyeballTag = "eyeball-network"
)

// RateLimitError says the hourly allowance is spent. It carries the wait the
// service asked for, so the caller can stop trying instead of burning the
// remaining checks on guaranteed failures.
type RateLimitError struct {
	Message string
	RetryIn time.Duration
}

func (e *RateLimitError) Error() string { return e.Message }

// Client talks to the Globalping API.
type Client struct {
	httpClient *http.Client
	apiToken   string // optional, raises the hourly quota
	baseURL    string
}

func NewClient(apiToken string) *Client {
	return &Client{
		httpClient: &http.Client{Timeout: httpTimeout},
		apiToken:   apiToken,
		baseURL:    APIURL,
	}
}

// CreateMeasurement asks the probes to run the check.
func (c *Client) CreateMeasurement(ctx context.Context, req *MeasurementRequest) (*MeasurementCreateResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("сборка запроса: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/measurements", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.apiToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.apiToken)
	}

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("сервис проверки не отвечает: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))

	if resp.StatusCode == http.StatusTooManyRequests {
		// The quota is counted in credits — one per probe — and is easy to
		// exhaust with a short interval and many probes. Saying so plainly
		// beats "API error 429". Typed, so the caller can stop spending until
		// the service says the allowance is back.
		retryIn := rateLimitResetIn(resp)
		return nil, &RateLimitError{
			RetryIn: retryIn,
			Message: fmt.Sprintf("превышен часовой лимит Globalping (%s); "+
				"следующая попытка через %s или уменьшите число зондов/частоту проверок%s",
				rateLimitLimit(resp), humanDuration(retryIn), tokenHint(c.apiToken == "")),
		}
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return nil, fmt.Errorf("сервис проверки ответил %d: %s", resp.StatusCode, snippet(respBody))
	}

	var result MeasurementCreateResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("разбор ответа: %w", err)
	}
	if result.ID == "" {
		return nil, fmt.Errorf("сервис проверки не вернул идентификатор измерения")
	}
	return &result, nil
}

// GetMeasurement fetches the current state of a measurement.
func (c *Client) GetMeasurement(ctx context.Context, id string) (*Measurement, error) {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/measurements/"+id, nil)
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Accept", "application/json")
	if c.apiToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.apiToken)
	}

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("сервис проверки не отвечает: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
		return nil, fmt.Errorf("сервис проверки ответил %d: %s", resp.StatusCode, snippet(body))
	}

	var result Measurement
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("разбор ответа: %w", err)
	}
	return &result, nil
}

// AwaitMeasurement polls until the probes are done or the deadline passes.
func (c *Client) AwaitMeasurement(ctx context.Context, id string, maxWait, pollInterval time.Duration) (*Measurement, error) {
	deadline := time.Now().Add(maxWait)

	for {
		m, err := c.GetMeasurement(ctx, id)
		if err != nil {
			return nil, err
		}
		if m.Status != "in-progress" {
			return m, nil
		}
		if time.Now().After(deadline) {
			// Out of time: return what there is. Probes that never answered
			// are reported as such rather than counted against the proxy.
			return m, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

// BuildMeasurementRequest describes the check: an HTTPS HEAD to the proxy port
// from Russian residential probes, with the FakeTLS domain in SNI.
func BuildMeasurementRequest(host string, port uint16, sni string, limit int) *MeasurementRequest {
	req := &MeasurementRequest{
		Type:   "http",
		Target: host,
		MeasurementOptions: MeasurementOptions{
			Protocol: "HTTPS",
			Port:     port,
			Request:  &RequestOptions{Method: "HEAD"},
		},
		Locations: []Location{{Country: "RU", Tags: []string{eyeballTag}}},
		Limit:     limit,
	}
	// Without this the probe sends the target address as SNI, and a proxy that
	// only answers on its FakeTLS domain would look broken.
	if sni != "" {
		req.MeasurementOptions.Request.Host = sni
	}
	return req
}

// AnalyzeMeasurement turns raw probe results into the panel's verdict.
func AnalyzeMeasurement(m *Measurement) *CheckResult {
	result := &CheckResult{
		Target:        m.Target,
		MeasurementID: m.ID,
		CheckedAt:     time.Now(),
		Probes:        make([]ProbeDetail, 0, len(m.Results)),
	}

	for _, pr := range m.Results {
		// Success is a completed handshake with a certificate: a TCP connect
		// alone says nothing about FakeTLS, and filtering usually shows up as
		// a session torn down mid-handshake.
		tlsSuccess := pr.Result.Status == "finished" && pr.Result.TLS != nil

		detail := ProbeDetail{
			City:           pr.Probe.City,
			Country:        pr.Probe.Country,
			Region:         pr.Probe.Region,
			Continent:      pr.Probe.Continent,
			ASN:            pr.Probe.ASN,
			Network:        pr.Probe.Network,
			Tags:           pr.Probe.Tags,
			Status:         pr.Result.Status,
			TLSSuccess:     tlsSuccess,
			TLSInfo:        pr.Result.TLS,
			HTTPStatusCode: pr.Result.StatusCode,
			RawOutput:      pr.Result.RawOutput,
		}
		if !tlsSuccess {
			detail.Error = strings.TrimSpace(pr.Result.RawOutput)
			if detail.Error == "" {
				switch pr.Result.Status {
				case "in-progress":
					detail.Error = "зонд не ответил вовремя"
				default:
					detail.Error = "соединение не установлено"
				}
			}
		}

		result.Probes = append(result.Probes, detail)
		if tlsSuccess {
			result.SuccessProbes++
		}
	}

	result.TotalProbes = len(m.Results)
	if result.TotalProbes > 0 {
		result.Percentage = float64(result.SuccessProbes) / float64(result.TotalProbes) * 100
	}

	switch {
	case result.Percentage >= 80:
		result.Level = LevelGreen
	case result.Percentage >= 50:
		result.Level = LevelYellow
	default:
		result.Level = LevelRed
	}
	return result
}

// ── Мелочи для сообщений об ошибках ─────────────────────────────────────────

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 300 {
		return s[:300] + "…"
	}
	return s
}

func rateLimitLimit(resp *http.Response) string {
	if v := resp.Header.Get("X-RateLimit-Limit"); v != "" {
		return v + " проверок в час"
	}
	return "квота исчерпана"
}

// rateLimitResetIn is how long the service says the allowance stays gone.
func rateLimitResetIn(resp *http.Response) time.Duration {
	v := resp.Header.Get("X-RateLimit-Reset")
	if v == "" {
		v = resp.Header.Get("Retry-After")
	}
	secs, err := strconv.Atoi(v)
	if err != nil || secs <= 0 {
		return time.Hour
	}
	return time.Duration(secs) * time.Second
}

func tokenHint(tokenless bool) string {
	if !tokenless {
		return ""
	}
	return ". Бесплатный токен на dash.globalping.io поднимает лимит вдвое: [globalping] api_token"
}
