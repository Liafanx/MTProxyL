package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
)

// ErrDCUnsupported means the installed MTProxyL predates the DC report.
var ErrDCUnsupported = errors.New(
	"установленный MTProxyL не отдаёт состояние DC — обновите его: mtproxyl update")

// DCStatus is `mtproxyl dc status --json` as is: the panel only shows it.
func (c *Client) DCStatus(ctx context.Context) (json.RawMessage, error) {
	out, err := c.run(ctx, "dc", "status", "--json")
	if err != nil {
		return nil, err
	}
	line := firstJSONLine(out)
	if !strings.HasPrefix(line, "{") || !json.Valid([]byte(line)) {
		return nil, ErrDCUnsupported
	}
	return json.RawMessage(line), nil
}
