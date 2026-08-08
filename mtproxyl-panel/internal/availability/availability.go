// Package availability checks whether the proxy answers from outside the
// server — from probes spread across several countries and providers.
//
// A proxy can be perfectly healthy locally and still be unreachable for its
// users: the port may be filtered by the hosting provider, blackholed by a
// national filter, or the whole address may be blocked in one country while
// working in the rest of the world. Nothing observable on the host itself
// tells that apart from "nobody is connecting today", so the check has to be
// made from the outside.
//
// The probes come from check-host.net: a free service that runs TCP connect
// checks from its own nodes and needs no account or key. The panel only talks
// HTTP to it — no privileges, no extra binaries, nothing to install.
package availability

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	apiBase = "https://check-host.net"
	// The service asks for this explicitly; without it the endpoints answer
	// with HTML meant for a browser.
	acceptJSON = "application/json"

	// A node that has not answered by then is reported as timed out. Checks
	// normally finish in a few seconds; the slow ones are exactly the blocked
	// ones, and waiting a full minute for them helps nobody.
	resultDeadline = 25 * time.Second
	pollInterval   = 2 * time.Second

	defaultMaxNodes = 12
	maxAllowedNodes = 30
)

// NodeResult is what one probe saw.
type NodeResult struct {
	// Node is check-host's own name for the probe, e.g. "ru1.node.check-host.net".
	Node        string `json:"node"`
	CountryCode string `json:"country_code"`
	Country     string `json:"country"`
	City        string `json:"city"`
	// OK is true when the probe completed a TCP handshake with the proxy.
	OK bool `json:"ok"`
	// TimeMS is how long the handshake took; 0 when it did not happen.
	TimeMS int `json:"time_ms"`
	// Error is the probe's own wording ("Connection timed out", "Refused"),
	// kept as-is: it distinguishes a filtered port from a closed one.
	Error string `json:"error,omitempty"`
	// Pending is true for a probe that never reported before the deadline.
	Pending bool `json:"pending,omitempty"`
}

// Phase is the lifecycle of a check.
type Phase string

const (
	PhaseIdle    Phase = "idle"
	PhaseRunning Phase = "running"
	PhaseDone    Phase = "done"
	PhaseFailed  Phase = "failed"
)

// Report is a snapshot of the last (or current) check.
type Report struct {
	Phase Phase  `json:"phase"`
	Host  string `json:"host,omitempty"`
	Port  int    `json:"port,omitempty"`
	// LocalOK reports whether the port answers on the server itself. It
	// separates "blocked on the way" from "not running at all" — without it a
	// row of failed probes is ambiguous.
	LocalOK      bool   `json:"local_ok"`
	LocalError   string `json:"local_error,omitempty"`
	LocalChecked bool   `json:"local_checked"`

	Nodes []NodeResult `json:"nodes"`
	// Reachable/Total count only probes that actually reported.
	Reachable int `json:"reachable"`
	Total     int `json:"total"`

	StartedAt  time.Time `json:"started_at,omitempty"`
	FinishedAt time.Time `json:"finished_at,omitempty"`
	Error      string    `json:"error,omitempty"`
	// PermanentLink is check-host's own page for this check, handy when someone
	// wants to show the result to a provider.
	PermanentLink string `json:"permanent_link,omitempty"`
}

// Checker runs one availability check at a time and keeps the last result.
//
// One at a time on purpose: the checks are outbound requests to a free public
// service, and a panel left open in three tabs would otherwise hammer it.
type Checker struct {
	mu     sync.Mutex
	report Report
	http   *http.Client
	// base is where the probe service lives; a field rather than the constant
	// so tests can answer for it.
	base string
}

func NewChecker() *Checker {
	return &Checker{
		report: Report{Phase: PhaseIdle},
		// Long enough for the polling loop, short enough that a hung service
		// does not pin the goroutine for minutes.
		http: &http.Client{Timeout: 20 * time.Second},
		base: apiBase,
	}
}

// Report returns the current snapshot.
func (c *Checker) Report() Report {
	c.mu.Lock()
	defer c.mu.Unlock()
	r := c.report
	r.Nodes = append([]NodeResult(nil), c.report.Nodes...)
	return r
}

// Busy reports whether a check is in flight.
func (c *Checker) Busy() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.report.Phase == PhaseRunning
}

// ValidateTarget checks what will be sent to the probe service.
//
// The host reaches an external API and is shown back in the UI, so it is
// bounded to what a proxy address can actually be: a hostname or an IP.
func ValidateTarget(host string, port int) error {
	if host == "" {
		return fmt.Errorf("не задан адрес сервера")
	}
	if len(host) > 253 {
		return fmt.Errorf("слишком длинный адрес")
	}
	if port < 1 || port > 65535 {
		return fmt.Errorf("порт должен быть в диапазоне 1-65535")
	}
	if ip := net.ParseIP(host); ip != nil {
		if ip.To4() == nil {
			// check-host's TCP check takes IPv4 or a hostname; an IPv6 literal
			// would come back as a parse error from the service itself.
			return fmt.Errorf("проверка идёт по IPv4 — укажите адрес IPv4 или домен")
		}
		return nil
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 {
			return fmt.Errorf("некорректный адрес сервера")
		}
		for _, r := range label {
			ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
				(r >= '0' && r <= '9') || r == '-' || r == '_'
			if !ok {
				return fmt.Errorf("некорректный адрес сервера")
			}
		}
	}
	return nil
}

// Start launches a check in the background. It returns false when one is
// already running.
func (c *Checker) Start(host string, port, maxNodes int) bool {
	if maxNodes <= 0 {
		maxNodes = defaultMaxNodes
	}
	if maxNodes > maxAllowedNodes {
		maxNodes = maxAllowedNodes
	}

	c.mu.Lock()
	if c.report.Phase == PhaseRunning {
		c.mu.Unlock()
		return false
	}
	c.report = Report{
		Phase:     PhaseRunning,
		Host:      host,
		Port:      port,
		StartedAt: time.Now(),
		Nodes:     []NodeResult{},
	}
	c.mu.Unlock()

	go c.run(host, port, maxNodes)
	return true
}

func (c *Checker) run(host string, port, maxNodes int) {
	ctx, cancel := context.WithTimeout(context.Background(), resultDeadline+30*time.Second)
	defer cancel()

	// The local dial first: it is instant and makes the outside results
	// readable ("closed everywhere" vs "closed only in one country").
	localOK, localErr := probeLocal(port)
	c.mu.Lock()
	c.report.LocalChecked = true
	c.report.LocalOK = localOK
	c.report.LocalError = localErr
	c.mu.Unlock()

	nodes, requestID, permalink, err := c.startRemote(ctx, host, port, maxNodes)
	if err != nil {
		c.finish(err)
		return
	}
	c.mu.Lock()
	c.report.PermanentLink = permalink
	c.mu.Unlock()

	results, err := c.pollResults(ctx, requestID, nodes)
	if err != nil {
		c.finish(err)
		return
	}

	reachable, total := summarize(results)
	c.mu.Lock()
	c.report.Nodes = results
	c.report.Reachable = reachable
	c.report.Total = total
	c.report.Phase = PhaseDone
	c.report.FinishedAt = time.Now()
	c.mu.Unlock()
}

// summarize counts the probes that actually reported.
//
// A node that stayed silent says nothing about the proxy, so it stays out of
// the denominator too: «доступен с 1 из 1» is honest, «с 1 из 2» would blame
// the proxy for a probe that never ran.
func summarize(results []NodeResult) (reachable, total int) {
	for _, n := range results {
		if n.Pending {
			continue
		}
		total++
		if n.OK {
			reachable++
		}
	}
	return reachable, total
}

func (c *Checker) finish(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.report.Phase = PhaseFailed
	c.report.Error = err.Error()
	c.report.FinishedAt = time.Now()
}

// probeLocal dials the port on the loopback interface.
func probeLocal(port int) (bool, string) {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 3*time.Second)
	if err != nil {
		return false, err.Error()
	}
	_ = conn.Close()
	return true, ""
}

// nodeInfo is check-host's description of one probe.
type nodeInfo struct {
	CountryCode string
	Country     string
	City        string
}

type startResponse struct {
	OK            int                 `json:"ok"`
	Error         string              `json:"error"`
	RequestID     string              `json:"request_id"`
	PermanentLink string              `json:"permanent_link"`
	Nodes         map[string][]string `json:"nodes"`
}

func (c *Checker) startRemote(ctx context.Context, host string, port, maxNodes int) (map[string]nodeInfo, string, string, error) {
	q := url.Values{}
	q.Set("host", net.JoinHostPort(host, strconv.Itoa(port)))
	q.Set("max_nodes", strconv.Itoa(maxNodes))
	endpoint := c.base + "/check-tcp?" + q.Encode()

	var sr startResponse
	if err := c.getJSON(ctx, endpoint, &sr); err != nil {
		return nil, "", "", fmt.Errorf("сервис проверки не отвечает: %w", err)
	}
	if sr.OK != 1 || sr.RequestID == "" {
		msg := sr.Error
		if msg == "" {
			msg = "сервис проверки отклонил запрос"
		}
		return nil, "", "", fmt.Errorf("%s", msg)
	}

	nodes := make(map[string]nodeInfo, len(sr.Nodes))
	for name, meta := range sr.Nodes {
		var info nodeInfo
		// Формат: [код страны, страна, город, ip, ASN]. Позиции после третьей
		// нам не нужны, а короткий массив встречается на новых узлах.
		if len(meta) > 0 {
			info.CountryCode = meta[0]
		}
		if len(meta) > 1 {
			info.Country = meta[1]
		}
		if len(meta) > 2 {
			info.City = meta[2]
		}
		nodes[name] = info
	}
	if len(nodes) == 0 {
		return nil, "", "", fmt.Errorf("сервис проверки не выделил ни одного узла")
	}
	return nodes, sr.RequestID, sr.PermanentLink, nil
}

// pollResults waits until every node has reported or the deadline passes.
func (c *Checker) pollResults(ctx context.Context, requestID string, nodes map[string]nodeInfo) ([]NodeResult, error) {
	deadline := time.Now().Add(resultDeadline)
	endpoint := c.base + "/check-result/" + url.PathEscape(requestID)

	var raw map[string]json.RawMessage
	for {
		// The first results appear about a second in; asking immediately would
		// only get a page of nulls.
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(pollInterval):
		}

		var current map[string]json.RawMessage
		if err := c.getJSON(ctx, endpoint, &current); err != nil {
			// A single failed poll is not fatal — the check keeps running on
			// their side and the next tick usually succeeds.
			if time.Now().After(deadline) {
				return nil, fmt.Errorf("не удалось получить результаты: %w", err)
			}
			continue
		}
		raw = current

		done := true
		for name := range nodes {
			v, ok := current[name]
			if !ok || len(v) == 0 || string(v) == "null" {
				done = false
				break
			}
		}
		if done {
			break
		}
		if time.Now().After(deadline) {
			break
		}
	}

	// Deterministic order: reachable last matters less than a list that does
	// not jump around between polls, so sort by country then node name.
	names := make([]string, 0, len(nodes))
	for name := range nodes {
		names = append(names, name)
	}
	sortNodeNames(names, nodes)

	out := make([]NodeResult, 0, len(names))
	for _, name := range names {
		info := nodes[name]
		res := NodeResult{
			Node:        name,
			CountryCode: strings.ToUpper(info.CountryCode),
			Country:     info.Country,
			City:        info.City,
		}
		v, ok := raw[name]
		if !ok || len(v) == 0 || string(v) == "null" {
			res.Pending = true
			res.Error = "узел не ответил вовремя"
			out = append(out, res)
			continue
		}
		parseNodeResult(v, &res)
		out = append(out, res)
	}
	return out, nil
}

// parseNodeResult reads one node's entry.
//
// check-host answers with an array of attempts; a successful TCP check looks
// like [{"address":"1.2.3.4","time":0.06}] and a failed one like
// [{"error":"Connection timed out"}].
func parseNodeResult(v json.RawMessage, res *NodeResult) {
	var attempts []struct {
		Address string  `json:"address"`
		Time    float64 `json:"time"`
		Error   string  `json:"error"`
	}
	if err := json.Unmarshal(v, &attempts); err != nil || len(attempts) == 0 {
		res.Error = "непонятный ответ узла"
		return
	}
	a := attempts[0]
	if a.Error != "" {
		res.Error = a.Error
		return
	}
	if a.Address == "" && a.Time == 0 {
		res.Error = "соединение не установлено"
		return
	}
	res.OK = true
	res.TimeMS = int(a.Time * 1000)
}

// sortNodeNames orders probes by country code, then city, then name.
func sortNodeNames(names []string, nodes map[string]nodeInfo) {
	// Insertion sort: the list is a dozen entries, and this keeps the
	// comparison in one place without pulling in a closure-heavy sort.
	for i := 1; i < len(names); i++ {
		for j := i; j > 0 && nodeLess(names[j], names[j-1], nodes); j-- {
			names[j], names[j-1] = names[j-1], names[j]
		}
	}
}

func nodeLess(a, b string, nodes map[string]nodeInfo) bool {
	na, nb := nodes[a], nodes[b]
	if na.CountryCode != nb.CountryCode {
		return na.CountryCode < nb.CountryCode
	}
	if na.City != nb.City {
		return na.City < nb.City
	}
	return a < b
}

func (c *Checker) getJSON(ctx context.Context, endpoint string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", acceptJSON)
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
