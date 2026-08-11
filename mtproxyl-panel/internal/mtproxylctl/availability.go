package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// The «Доступность из России» check lives in MTProxyL, not here: the telegram
// bot and the systemd timer need it too, and a verdict that only exists while
// a browser tab is open is no verdict at all. The panel reads what the script
// has already measured and asks it for a fresh check.

// AvailabilityTarget is what the next check will connect to. Override holds the
// operator's answers as typed — empty means «determine automatically».
type AvailabilityTarget struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	SNI      string `json:"sni"`
	Override struct {
		Host string `json:"host"`
		Port string `json:"port"`
		SNI  string `json:"sni"`
	} `json:"override"`
}

// OverridePort is the pinned port as a number; 0 when it is left automatic.
func (t AvailabilityTarget) OverridePort() int {
	n, err := strconv.Atoi(strings.TrimSpace(t.Override.Port))
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// AvailabilityState is `mtproxyl availability status --json`. Quota and Result
// travel as raw JSON: the panel only reshapes the envelope, and re-encoding the
// probe list would mean keeping two copies of its schema in step.
type AvailabilityState struct {
	Enabled     bool               `json:"enabled"`
	AutoCheck   bool               `json:"auto_check"`
	TimerActive bool               `json:"timer_active"`
	Interval    int                `json:"interval"`
	Probes      int                `json:"probes"`
	Threshold   int                `json:"threshold"`
	NextRun     string             `json:"next_run"`
	Quota       json.RawMessage    `json:"quota"`
	Target      AvailabilityTarget `json:"target"`
	Result      json.RawMessage    `json:"result"`
	Message     string             `json:"message"`
}

// ErrAvailabilityUnsupported means the installed MTProxyL predates the check.
// Панель обновляется отдельно от скрипта, и такая пара — обычное дело.
var ErrAvailabilityUnsupported = errors.New("установленный MTProxyL не умеет проверять доступность")

// CheckRejected is a refusal that is not a failure: the quota is spent or the
// previous check was a moment ago. The message is the script's own.
type CheckRejected struct{ Message string }

func (e *CheckRejected) Error() string { return e.Message }

// AvailabilityStatus returns the last verdict without the probe list.
func (c *Client) AvailabilityStatus(ctx context.Context) (*AvailabilityState, error) {
	return c.availabilityState(ctx, "status", "--json")
}

// AvailabilityDetails returns the same with every probe.
func (c *Client) AvailabilityDetails(ctx context.Context) (*AvailabilityState, error) {
	return c.availabilityState(ctx, "details")
}

func (c *Client) availabilityState(ctx context.Context, args ...string) (*AvailabilityState, error) {
	out, err := c.run(ctx, append([]string{"availability"}, args...)...)
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrAvailabilityUnsupported
		}
		return nil, err
	}
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrAvailabilityUnsupported
	}
	var st AvailabilityState
	if err := json.Unmarshal([]byte(line), &st); err != nil {
		return nil, fmt.Errorf("parse availability: %w", err)
	}
	return &st, nil
}

// AvailabilityCheck runs one check now. A refusal comes back as *CheckRejected.
func (c *Client) AvailabilityCheck(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "availability", "check", "--json")
	line := firstJSONLine(out)
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrAvailabilityUnsupported
		}
		// Отказ скрипт печатает тем же JSON, что и результат: его текст
		// человеку понятнее, чем «exit status 1».
		if msg := availabilityErrorField(line); msg != "" {
			return nil, &CheckRejected{Message: msg}
		}
		return nil, err
	}
	if line == "" {
		return nil, ErrAvailabilityUnsupported
	}
	if msg := availabilityErrorField(line); msg != "" {
		return nil, &CheckRejected{Message: msg}
	}
	return json.RawMessage(line), nil
}

// AvailabilitySetAutoCheck turns scheduled checks on or off. Manual checks keep
// working either way — the button is pressed by a human who decides for himself.
func (c *Client) AvailabilitySetAutoCheck(ctx context.Context, on bool) error {
	action := "off"
	if on {
		action = "on"
	}
	out, err := c.run(ctx, "availability", action)
	if err != nil && unsupportedCommand(out, err) {
		return ErrAvailabilityUnsupported
	}
	return err
}

// AvailabilitySetToken stores the Globalping token; an empty one clears it.
func (c *Client) AvailabilitySetToken(ctx context.Context, token string) error {
	arg := strings.TrimSpace(token)
	if arg == "" {
		arg = "--clear"
	}
	out, err := c.run(ctx, "availability", "token", arg)
	if err != nil && unsupportedCommand(out, err) {
		return ErrAvailabilityUnsupported
	}
	return err
}

// availabilityErrorField reads the "error" field of a one-line JSON answer.
func availabilityErrorField(line string) string {
	if line == "" {
		return ""
	}
	var probe struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(line), &probe); err != nil {
		return ""
	}
	return probe.Error
}

// unsupportedCommand recognises an MTProxyL that does not know the subcommand.
func unsupportedCommand(out string, err error) bool {
	var ce *CommandError
	if errors.As(err, &ce) && strings.Contains(ce.Output, "Неизвестная команда") {
		return true
	}
	return strings.Contains(out, "Неизвестная команда")
}
