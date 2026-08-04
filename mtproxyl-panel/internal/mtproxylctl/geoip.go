package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
)

// GeoIPStatus is the output of `mtproxyl geoip status --json`.
type GeoIPStatus struct {
	CityInstalled bool   `json:"city_installed"`
	ASNInstalled  bool   `json:"asn_installed"`
	Dir           string `json:"dir"`
}

// GeoIPStatusFn reads whether the GeoLite2 databases are installed.
//
// Independent of manager/reanimator: the databases live in a system-wide
// directory, not the target's config, so this works the same in both modes.
func (c *Client) GeoIPStatus(ctx context.Context) (*GeoIPStatus, error) {
	out, err := c.run(ctx, "geoip", "status", "--json")
	if err != nil {
		return nil, err
	}
	var st GeoIPStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse geoip status: %w", err)
	}
	return &st, nil
}

// InstallGeoIP downloads the GeoLite2 City and ASN databases (P3TERX mirror)
// into the system GeoIP directory. Slow on a first run, hence run through the
// same background-operation runner as PQ nginx and other long installs.
func (c *Client) InstallGeoIP(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "geoip", "install")
	return stripANSI(out), err
}
