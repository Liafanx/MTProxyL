package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
)

// TargetSnapshot returns `mtproxyl target-api snapshot`: an mtdd target's
// users, counters and DC state shaped like telemt's API answers. One call
// serves every page and the history recorder.
func (c *Client) TargetSnapshot(ctx context.Context) ([]byte, error) {
	out, err := c.run(ctx, "target-api", "snapshot")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("target-api snapshot: invalid JSON")
	}
	return []byte(line), nil
}

// MediaLimits are mtdd's built-in limits for media downloads, kbit/s; 0 means
// no limit.
type MediaLimits struct {
	Available bool  `json:"available"`
	UserKbps  int64 `json:"user_kbps"`
	TotalKbps int64 `json:"total_kbps"`
}

// GetMtddIPStats returns `mtproxyl metrics ips --json`: mtdd unique IPs, online
// and HyperLogLog history (seen and active). The document is passed through as is.
func (c *Client) GetMtddIPStats(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "metrics", "ips", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("metrics ips: invalid JSON")
	}
	return json.RawMessage(line), nil
}

// GetMediaLimits returns `mtproxyl media status --json`.
func (c *Client) GetMediaLimits(ctx context.Context) (*MediaLimits, error) {
	out, err := c.run(ctx, "media", "status", "--json")
	if err != nil {
		return nil, err
	}
	var m MediaLimits
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &m); err != nil {
		return nil, fmt.Errorf("parse media status: %w", err)
	}
	return &m, nil
}

// SetMediaLimits sets per-user and server-wide media limits in Mbit/s; zero
// for both removes them.
func (c *Client) SetMediaLimits(ctx context.Context, userMbps, totalMbps float64) (string, error) {
	if userMbps < 0 || totalMbps < 0 || userMbps > 100000 || totalMbps > 100000 {
		return "", fmt.Errorf("лимит: от 0 до 100000 Мбит/с")
	}
	if userMbps == 0 && totalMbps == 0 {
		out, err := c.run(ctx, "media", "off")
		return stripANSI(out), err
	}
	out, err := c.run(ctx, "media", "set",
		strconv.FormatFloat(userMbps, 'f', -1, 64), strconv.FormatFloat(totalMbps, 'f', -1, 64))
	return stripANSI(out), err
}

// GetMtddSuspects returns `mtproxyl suspects status --json`: mtdd's suspect
// table plus its settings and how many addresses are already in the IP block
// list. The document is passed through as is.
func (c *Client) GetMtddSuspects(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "suspects", "status", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("suspects status: invalid JSON")
	}
	return json.RawMessage(line), nil
}

// SetMtddSuspectsEnabled turns mtdd's suspect accounting on or off.
func (c *Client) SetMtddSuspectsEnabled(ctx context.Context, on bool) (string, error) {
	arg := "off"
	if on {
		arg = "on"
	}
	out, err := c.run(ctx, "suspects", arg)
	return stripANSI(out), err
}

// SetMtddSuspectsBan sets mtdd's shadow-ban score; 0 turns the ban off.
func (c *Client) SetMtddSuspectsBan(ctx context.Context, score int) (string, error) {
	if score < 0 || score > 100 {
		return "", fmt.Errorf("score: от 0 до 100")
	}
	out, err := c.run(ctx, "suspects", "ban", strconv.Itoa(score))
	return stripANSI(out), err
}

// MtddSuspectsBlock adds suspects with score >= minScore to the IP block list.
func (c *Client) MtddSuspectsBlock(ctx context.Context, minScore int) (string, error) {
	if minScore < 1 || minScore > 100 {
		return "", fmt.Errorf("score: от 1 до 100")
	}
	out, err := c.run(ctx, "suspects", "block", strconv.Itoa(minScore))
	return stripANSI(out), err
}

// MtddSuspectsUnblock removes only the entries suspects block added.
func (c *Client) MtddSuspectsUnblock(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "suspects", "unblock")
	return stripANSI(out), err
}
