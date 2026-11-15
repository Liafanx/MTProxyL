package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
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

// GetMtddAdTag returns `mtproxyl adtag show --json`: the temporary ad tag
// override and whether one is active. The document is passed through as is.
func (c *Client) GetMtddAdTag(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "adtag", "show", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("adtag show: invalid JSON")
	}
	return json.RawMessage(line), nil
}

// SetMtddAdTag overrides the shared ad tag at runtime, without a restart and
// without touching the config file.
func (c *Client) SetMtddAdTag(ctx context.Context, tag string) (string, error) {
	tag = strings.ToLower(strings.TrimSpace(tag))
	if !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(tag) || tag == strings.Repeat("0", 32) {
		return "", fmt.Errorf("тег: 32 шестнадцатеричных символа, не из одних нулей")
	}
	out, err := c.run(ctx, "adtag", "set", tag)
	return stripANSI(out), err
}

// ResetMtddAdTag drops the runtime override, returning to the configured tag.
func (c *Client) ResetMtddAdTag(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "adtag", "reset")
	return stripANSI(out), err
}

// GetMtddEvents returns `mtproxyl events --limit N --json`: the engine's ring
// buffer of the last successful admin changes.
func (c *Client) GetMtddEvents(ctx context.Context, limit int) (json.RawMessage, error) {
	if limit < 1 || limit > 256 {
		return nil, fmt.Errorf("limit: 1..256")
	}
	out, err := c.run(ctx, "events", "--limit", strconv.Itoa(limit), "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !json.Valid([]byte(line)) {
		return nil, fmt.Errorf("events: invalid JSON")
	}
	return json.RawMessage(line), nil
}
