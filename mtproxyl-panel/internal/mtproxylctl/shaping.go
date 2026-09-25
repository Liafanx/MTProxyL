package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"regexp"
)

// ShapingConfig is owned by MTProxyL, not telemt's read-only API mount.
type ShapingConfig struct {
	Enabled         bool     `json:"enabled"`
	Mode            string   `json:"mode"`
	ChannelMbps     int      `json:"channel_mbps"`
	ReservePercent  int      `json:"reserve_percent"`
	ExpectedUsers   int      `json:"expected_users"`
	ManualTotalMbps int      `json:"manual_total_mbps"`
	ManualIPMbps    float64  `json:"manual_ip_mbps"`
	ProfileExempt   []string `json:"profile_exempt"`
	IPExempt        []string `json:"ip_exempt"`
}

type ShapingStatus struct {
	Config ShapingConfig `json:"config"`
	State  struct {
		ActiveIPs       int    `json:"active_ips"`
		LastUpdateEpoch int64  `json:"last_update_epoch"`
		LastSampleEpoch int64  `json:"last_sample_epoch"`
		LastError       string `json:"last_error"`
	} `json:"state"`
	Rates struct {
		TotalBps    int64 `json:"total_bps"`
		IPBps       int64 `json:"ip_bps"`
		Denominator *int  `json:"denominator"`
	} `json:"rates"`
	TCActive   bool   `json:"tc_active"`
	TrackedIPs int    `json:"tracked_ips"`
	Interface  string `json:"interface"`
}

var shapingProfileName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

func ValidateShapingConfig(c ShapingConfig) error {
	if c.Mode != "manual" && c.Mode != "fixed" && c.Mode != "dynamic" {
		return errors.New("неизвестный режим")
	}
	if c.ChannelMbps < 1 || c.ChannelMbps > 100000 || c.ReservePercent < 0 || c.ReservePercent > 90 || c.ExpectedUsers < 2 || c.ExpectedUsers > 100000 {
		return errors.New("ширина канала, резерв или число пользователей вне диапазона")
	}
	if c.ManualTotalMbps < 1 || c.ManualTotalMbps > 100000 || c.ManualIPMbps < 0.1 || c.ManualIPMbps > float64(c.ManualTotalMbps) {
		return errors.New("ручной лимит вне диапазона")
	}
	if len(c.ProfileExempt) > 1000 || len(c.IPExempt) > 100 {
		return errors.New("слишком много исключений")
	}
	for _, name := range c.ProfileExempt {
		if !shapingProfileName.MatchString(name) {
			return fmt.Errorf("недопустимый профиль %q", name)
		}
	}
	for _, cidr := range c.IPExempt {
		ip := net.ParseIP(cidr)
		if ip == nil {
			var err error
			ip, _, err = net.ParseCIDR(cidr)
			if err != nil {
				return fmt.Errorf("недопустимый IPv4/CIDR %q", cidr)
			}
		}
		if ip.To4() == nil {
			return fmt.Errorf("ожидался IPv4/CIDR: %q", cidr)
		}
	}
	return nil
}

func (c *Client) ShapingStatus(ctx context.Context) (ShapingStatus, error) {
	out, err := c.run(ctx, "shaping", "status", "--json")
	if err != nil {
		return ShapingStatus{}, err
	}
	var status ShapingStatus
	if err := json.Unmarshal([]byte(out), &status); err != nil {
		return ShapingStatus{}, fmt.Errorf("parse shaping status: %w", err)
	}
	return status, nil
}

func (c *Client) ApplyShaping(ctx context.Context, cfg ShapingConfig) (string, error) {
	if err := ValidateShapingConfig(cfg); err != nil {
		return "", err
	}
	if cfg.ProfileExempt == nil {
		cfg.ProfileExempt = []string{}
	}
	if cfg.IPExempt == nil {
		cfg.IPExempt = []string{}
	}
	data, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return c.runWithStdin(ctx, string(data), "shaping", "apply")
}
