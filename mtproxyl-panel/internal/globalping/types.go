// Package globalping checks whether the proxy is reachable from Russia as
// ordinary home users see it.
//
// Probes must sit on eyeball networks: filtering applies to subscriber traffic,
// and a probe in a data centre routinely sees a server its users cannot reach.
// The check is an HTTPS HEAD to the proxy port with the FakeTLS domain in SNI,
// and success is a returned TLS certificate — the same handshake a Telegram
// client performs, so it also catches a port that answers but tears the
// session down mid-handshake.
package globalping

import (
	"sync"
	"time"
)

// ── Globalping API ──────────────────────────────────────────────────────────

// MeasurementRequest is the body of POST /v1/measurements.
type MeasurementRequest struct {
	Type               string             `json:"type"`
	Target             string             `json:"target"`
	MeasurementOptions MeasurementOptions `json:"measurementOptions"`
	Locations          []Location         `json:"locations"`
	Limit              int                `json:"limit"`
}

type MeasurementOptions struct {
	Protocol string          `json:"protocol"`
	Port     uint16          `json:"port"`
	Request  *RequestOptions `json:"request,omitempty"`
}

type RequestOptions struct {
	Method string `json:"method"`
	// Host goes into the Host header and, for HTTPS, into the TLS SNI
	// extension — which is exactly what makes this a FakeTLS check.
	Host string `json:"host,omitempty"`
}

type Location struct {
	Country string   `json:"country,omitempty"`
	Tags    []string `json:"tags,omitempty"`
}

// MeasurementCreateResponse is the answer to a create call.
type MeasurementCreateResponse struct {
	ID          string `json:"id"`
	ProbesCount int    `json:"probesCount"`
}

// Measurement is the full result of GET /v1/measurements/{id}.
type Measurement struct {
	ID          string        `json:"id"`
	Type        string        `json:"type"`
	Status      string        `json:"status"`
	CreatedAt   string        `json:"createdAt"`
	UpdatedAt   string        `json:"updatedAt"`
	Target      string        `json:"target"`
	ProbesCount int           `json:"probesCount"`
	Results     []ProbeResult `json:"results"`
}

type ProbeResult struct {
	Probe  Probe  `json:"probe"`
	Result Result `json:"result"`
}

type Probe struct {
	Continent string   `json:"continent"`
	Region    string   `json:"region"`
	Country   string   `json:"country"`
	State     string   `json:"state"`
	City      string   `json:"city"`
	ASN       int      `json:"asn"`
	Network   string   `json:"network"`
	Tags      []string `json:"tags"`
}

type Result struct {
	Status         string   `json:"status"`
	RawOutput      string   `json:"rawOutput"`
	StatusCode     int      `json:"statusCode,omitempty"`
	StatusCodeName string   `json:"statusCodeName,omitempty"`
	TLS            *TLSInfo `json:"tls,omitempty"`
}

type TLSInfo struct {
	Authorized bool       `json:"authorized"`
	CreatedAt  string     `json:"createdAt"`
	ExpiresAt  string     `json:"expiresAt"`
	Issuer     TLSIssuer  `json:"issuer"`
	Subject    TLSSubject `json:"subject"`
}

type TLSIssuer struct {
	C  string `json:"C"`
	O  string `json:"O"`
	CN string `json:"CN"`
}

type TLSSubject struct {
	CN  string `json:"CN"`
	Alt string `json:"alt"`
}

// ── Результаты ──────────────────────────────────────────────────────────────

// Level is the traffic-light shown on the dashboard.
type Level string

const (
	LevelGreen  Level = "green"  // 80–100%
	LevelYellow Level = "yellow" // 50–80%
	LevelRed    Level = "red"    // 0–50%
)

// ProbeDetail is what one probe saw.
type ProbeDetail struct {
	City      string   `json:"city"`
	Country   string   `json:"country"`
	Region    string   `json:"region"`
	Continent string   `json:"continent"`
	ASN       int      `json:"asn"`
	Network   string   `json:"network"`
	Tags      []string `json:"tags"`
	Status    string   `json:"status"`
	// TLSSuccess is the verdict for this probe: the handshake completed and a
	// certificate came back.
	TLSSuccess     bool     `json:"tls_success"`
	TLSInfo        *TLSInfo `json:"tls_info,omitempty"`
	HTTPStatusCode int      `json:"http_status_code,omitempty"`
	RawOutput      string   `json:"raw_output"`
	Error          string   `json:"error,omitempty"`
}

// CheckResult is one complete check.
type CheckResult struct {
	Percentage    float64       `json:"percentage"`
	Level         Level         `json:"level"`
	TotalProbes   int           `json:"total_probes"`
	SuccessProbes int           `json:"success_probes"`
	Target        string        `json:"target"`
	MeasurementID string        `json:"measurement_id"`
	CheckedAt     time.Time     `json:"checked_at"`
	Probes        []ProbeDetail `json:"probes,omitempty"`
	Error         string        `json:"error,omitempty"`
}

// Store keeps the last result for the UI to read.
type Store struct {
	mu     sync.RWMutex
	result *CheckResult
}

func NewStore() *Store {
	return &Store{}
}

func (s *Store) Set(result *CheckResult) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.result = result
}

// Get returns a copy of the last result, probe list included.
func (s *Store) Get() *CheckResult {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.result == nil {
		return nil
	}
	out := *s.result
	if s.result.Probes != nil {
		out.Probes = make([]ProbeDetail, len(s.result.Probes))
		copy(out.Probes, s.result.Probes)
	}
	return &out
}

// GetStatus returns the summary without the probe list — what the dashboard
// indicator polls, and it has no use for two dozen raw outputs.
func (s *Store) GetStatus() *CheckResult {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.result == nil {
		return nil
	}
	return &CheckResult{
		Percentage:    s.result.Percentage,
		Level:         s.result.Level,
		TotalProbes:   s.result.TotalProbes,
		SuccessProbes: s.result.SuccessProbes,
		Target:        s.result.Target,
		MeasurementID: s.result.MeasurementID,
		CheckedAt:     s.result.CheckedAt,
		Error:         s.result.Error,
	}
}
