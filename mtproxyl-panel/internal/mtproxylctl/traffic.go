package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
)

// TrafficUser is one row of the traffic report. In and Out matter only when
// TrafficReport.Directional is set; otherwise only Total carries data.
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
	// Deleted marks the aggregate row for users that no longer exist. Their
	// traffic was really spent and stays in the totals, so dropping the row
	// would make the per-user column stop adding up to "total".
	Deleted bool `json:"deleted"`
}

// TrafficTotals aggregates the report across users.
type TrafficTotals struct {
	In          int64 `json:"in"`
	Out         int64 `json:"out"`
	Total       int64 `json:"total"`
	SessionIn   int64 `json:"session_in"`
	SessionOut  int64 `json:"session_out"`
	Connections int64 `json:"connections"`
	UniqueIPs   int64 `json:"unique_ips"`
}

// TrafficReport is the output of `mtproxyl traffic --json`. The two flags say
// how far the numbers can be trusted: Directional — upload and download are
// separate; Persistent — they survive an engine restart (manager mode only).
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
