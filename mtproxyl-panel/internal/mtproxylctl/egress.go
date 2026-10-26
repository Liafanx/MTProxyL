package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
)

// EgressAwg — подробности, когда выход идёт через свой AWG.
type EgressAwg struct {
	Order         []string        `json:"order"`
	FailoverAfter int             `json:"failover_after"`
	FailbackEvery int             `json:"failback_every"`
	LastSwitch    AwgSwitch       `json:"last_switch"`
	PrimaryCheck  AwgPrimaryCheck `json:"primary_check"`
}

// Egress is `mtproxyl egress --json`: через что движок выходит к Telegram.
type Egress struct {
	// Via: direct, warp, donor или awg.
	Via      string `json:"via"`
	Label    string `json:"label"`
	Name     string `json:"name"`
	EgressIP string `json:"egress_ip"`
	// Ok: nil — давно не проверяли.
	Ok        *bool      `json:"ok"`
	Error     string     `json:"error"`
	FailSince int64      `json:"fail_since"`
	Awg       *EgressAwg `json:"awg,omitempty"`
}

var ErrEgressUnsupported = fmt.Errorf("установленный MTProxyL не сообщает выход к Telegram")

func (c *Client) GetEgress(ctx context.Context) (*Egress, error) {
	out, err := c.run(ctx, "egress", "--json")
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrEgressUnsupported
		}
		return nil, err
	}
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrEgressUnsupported
	}
	var e Egress
	if err := json.Unmarshal([]byte(line), &e); err != nil {
		return nil, fmt.Errorf("parse egress: %w", err)
	}
	return &e, nil
}
