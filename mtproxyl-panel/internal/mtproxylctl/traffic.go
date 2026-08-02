package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
)

// TrafficUser is one row of the traffic report.
//
// In and Out are only meaningful when TrafficReport.Directional is set; when it
// is not, the source could not split directions and only Total carries data.
type TrafficUser struct {
	User string `json:"user"`
	In   int64  `json:"in"`
	Out  int64  `json:"out"`
	// Total is In+Out for directional sources, and the source's own single
	// counter otherwise.
	Total       int64 `json:"total"`
	SessionIn   int64 `json:"session_in"`
	SessionOut  int64 `json:"session_out"`
	Connections int64 `json:"connections"`
	UniqueIPs   int64 `json:"unique_ips"`
	Enabled     bool  `json:"enabled"`
}

// TrafficTotals aggregates the report across users.
type TrafficTotals struct {
	In          int64 `json:"in"`
	Out         int64 `json:"out"`
	Total       int64 `json:"total"`
	SessionIn   int64 `json:"session_in"`
	SessionOut  int64 `json:"session_out"`
	Connections int64 `json:"connections"`
}

// TrafficReport is the output of `mtproxyl traffic --json`.
//
// The two flags describe how far the numbers can be trusted, and the UI has to
// honour them: Directional says whether upload and download are separate
// figures, Persistent whether they survive an engine restart. Only manager mode
// keeps its own database; against a foreign target we read that target's
// counters, which reset when it does.
type TrafficReport struct {
	Mode string `json:"mode"`
	// Source is "db" (manager's own accounting), "metrics" (the target's
	// Prometheus endpoint), "api" (the target's HTTP API) or "none".
	Source      string        `json:"source"`
	Directional bool          `json:"directional"`
	Persistent  bool          `json:"persistent"`
	Error       string        `json:"error,omitempty"`
	Totals      TrafficTotals `json:"totals"`
	Users       []TrafficUser `json:"users"`
}

// Traffic returns accumulated per-user traffic.
func (c *Client) Traffic(ctx context.Context) (*TrafficReport, error) {
	out, err := c.run(ctx, "traffic", "--json")
	if err != nil {
		return nil, err
	}
	var rep TrafficReport
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &rep); err != nil {
		return nil, fmt.Errorf("parse traffic report: %w", err)
	}
	if rep.Users == nil {
		rep.Users = []TrafficUser{}
	}
	return &rep, nil
}
