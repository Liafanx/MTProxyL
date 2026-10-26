package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// AwgCheck is the last probe of the tunnel.
type AwgCheck struct {
	At     int64  `json:"at"`
	Result string `json:"result"`
	Error  string `json:"error"`
}

// AwgConfig is an imported client config; keys never leave the server.
type AwgConfig struct {
	Name        string `json:"name"`
	Endpoint    string `json:"endpoint"`
	Address     string `json:"address"`
	Obfuscation bool   `json:"obfuscation"`
}

// AwgStatus is `mtproxyl awg status --json`.
type AwgStatus struct {
	Enabled      bool   `json:"enabled"`
	Active       string `json:"active"`
	Mtu          *int   `json:"mtu"`
	Iface        string `json:"iface"`
	AwgInstalled bool   `json:"awg_installed"`
	TunnelUp     bool   `json:"tunnel_up"`
	Rules        bool   `json:"rules"`
	HandshakeAge *int64 `json:"handshake_age"`
	RxBytes      int64  `json:"rx_bytes"`
	TxBytes      int64  `json:"tx_bytes"`
	EgressIP     string `json:"egress_ip"`
	IPv6         bool   `json:"ipv6"`
	// MeMode: natip — ME через адрес выхода туннеля.
	MeMode     string `json:"me_mode"`
	MeDisabled bool   `json:"me_disabled"`
	// EngineMode: manager, target или manual — как у донора.
	EngineMode   string      `json:"engine_mode"`
	EngineRouted string      `json:"engine_routed"`
	WarpEnabled  bool        `json:"warp_enabled"`
	DonorEnabled bool        `json:"donor_enabled"`
	EnabledAt    int64       `json:"enabled_at"`
	Check        AwgCheck    `json:"check"`
	Configs      []AwgConfig `json:"configs"`
}

// AwgScanFile is a candidate config found on the server.
type AwgScanFile struct {
	Path        string `json:"path"`
	Name        string `json:"name"`
	Valid       bool   `json:"valid"`
	Endpoint    string `json:"endpoint"`
	Address     string `json:"address"`
	Obfuscation bool   `json:"obfuscation"`
	IPv6        bool   `json:"ipv6"`
	Error       string `json:"error"`
}

// AwgEnableRequest — какой конфиг включить и что разрешено.
type AwgEnableRequest struct {
	Name           string `json:"name"`
	Mtu            int    `json:"mtu"`
	AllowDisableMe bool   `json:"allow_disable_me"`
}

var (
	ErrAwgUnsupported = fmt.Errorf("установленный MTProxyL не умеет выход через свой AWG")
	awgNameRe         = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$`)
	awgPathRe         = regexp.MustCompile(`^/[A-Za-z0-9._/@+ -]{1,255}\.conf$`)
)

const AwgConfigMax = 64 << 10

func ValidateAwgName(name string) error {
	if !awgNameRe.MatchString(name) {
		return fmt.Errorf("имя: латиница, цифры, «-» и «_», до 32 символов")
	}
	return nil
}

func ValidateAwgPath(p string) error {
	if !awgPathRe.MatchString(p) || filepath.Clean(p) != p || strings.Contains(p, "/../") {
		return fmt.Errorf("нужен полный путь к файлу .conf")
	}
	return nil
}

func validAwgMtu(m int) bool { return m == 0 || (m >= 1200 && m <= 1500) }

func (c *Client) AwgGetStatus(ctx context.Context) (*AwgStatus, error) {
	out, err := c.run(ctx, "awg", "status", "--json")
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrAwgUnsupported
		}
		return nil, err
	}
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrAwgUnsupported
	}
	var st AwgStatus
	if err := json.Unmarshal([]byte(line), &st); err != nil {
		return nil, fmt.Errorf("parse awg status: %w", err)
	}
	if st.Configs == nil {
		st.Configs = []AwgConfig{}
	}
	return &st, nil
}

func (c *Client) AwgScan(ctx context.Context) ([]AwgScanFile, error) {
	out, err := c.run(ctx, "awg", "scan", "--json")
	if err != nil {
		return nil, err
	}
	var res struct {
		Files []AwgScanFile `json:"files"`
	}
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &res); err != nil {
		return nil, fmt.Errorf("не удалось прочитать список конфигов")
	}
	if res.Files == nil {
		res.Files = []AwgScanFile{}
	}
	return res.Files, nil
}

// AwgImport saves an uploaded config; the body goes through stdin.
func (c *Client) AwgImport(ctx context.Context, name, body string) (string, error) {
	if err := ValidateAwgName(name); err != nil {
		return "", err
	}
	if len(body) == 0 || len(body) > AwgConfigMax {
		return "", fmt.Errorf("пустой файл или больше 64 КБ")
	}
	out, err := c.runWithStdin(ctx, body, "awg", "import", "-", "--name", name)
	return stripANSI(out), err
}

// AwgImportPath imports a config found on the server.
func (c *Client) AwgImportPath(ctx context.Context, path, name string) (string, error) {
	if err := ValidateAwgPath(path); err != nil {
		return "", err
	}
	if err := ValidateAwgName(name); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "awg", "import", path, "--name", name)
	return stripANSI(out), err
}

func (r AwgEnableRequest) args() ([]string, error) {
	if err := ValidateAwgName(r.Name); err != nil {
		return nil, err
	}
	if !validAwgMtu(r.Mtu) {
		return nil, fmt.Errorf("MTU: 1200–1500")
	}
	args := []string{"awg", "on", r.Name, "--yes"}
	if r.Mtu != 0 {
		args = append(args, "--mtu", strconv.Itoa(r.Mtu))
	}
	if r.AllowDisableMe {
		args = append(args, "--allow-disable-me")
	}
	return args, nil
}

// Validate reports an input error before any operation starts.
func (r AwgEnableRequest) Validate() error {
	_, err := r.args()
	return err
}

func (c *Client) AwgEnable(ctx context.Context, r AwgEnableRequest) (string, error) {
	args, err := r.args()
	if err != nil {
		return "", err
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

func (c *Client) AwgDisable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "awg", "off")
	return stripANSI(out), err
}

func (c *Client) AwgCheck(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "awg", "check", "--json")
	return stripANSI(out), err
}

func (c *Client) AwgRemove(ctx context.Context, name string) (string, error) {
	if err := ValidateAwgName(name); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "awg", "remove", name)
	return stripANSI(out), err
}
