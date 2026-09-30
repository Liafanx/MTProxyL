package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

// DonorCheck is the last probe of the tunnel: egress IP and a live Telegram answer.
type DonorCheck struct {
	At       int64  `json:"at"`
	Result   string `json:"result"`
	EgressIP string `json:"egress_ip"`
	RttMs    *int64 `json:"rtt_ms"`
	Error    string `json:"error"`
}

// DonorStatus is `mtproxyl donor status --json`.
type DonorStatus struct {
	Configured bool `json:"configured"`
	// Stage: "" (не настроен), pending (ждёт ключ донора), ready.
	Stage        string `json:"stage"`
	Enabled      bool   `json:"enabled"`
	SetupMode    string `json:"setup_mode"`
	Host         string `json:"host"`
	SSHPort      int    `json:"ssh_port"`
	SSHUser      string `json:"ssh_user"`
	AwgPort      int    `json:"awg_port"`
	Net          string `json:"net"`
	Iface        string `json:"iface"`
	RemoteIface  string `json:"remote_iface"`
	Socks        string `json:"socks"`
	AwgInstalled bool   `json:"awg_installed"`
	TunnelUp     bool   `json:"tunnel_up"`
	HandshakeAge *int64 `json:"handshake_age"`
	RxBytes      int64  `json:"rx_bytes"`
	TxBytes      int64  `json:"tx_bytes"`
	EgressIP     string `json:"egress_ip"`
	PublicIP     string `json:"public_ip"`
	IPv6         bool   `json:"ipv6"`
	// EngineMode: manager — маршрут в своём конфиге, target — в конфиге цели,
	// manual — конфиг чужой и панель его не правит.
	EngineMode        string     `json:"engine_mode"`
	EngineRouted      string     `json:"engine_routed"`
	DisabledUpstreams string     `json:"disabled_upstreams"`
	DefaultUpstreams  string     `json:"default_upstreams"`
	WarpEnabled       bool       `json:"warp_enabled"`
	SetupAt           int64      `json:"setup_at"`
	Check             DonorCheck `json:"check"`
	ManualScript      bool       `json:"manual_script"`
}

// DonorHostKey is one SSH host key fingerprint of the donor.
type DonorHostKey struct {
	Fingerprint string `json:"fingerprint"`
	Type        string `json:"type"`
}

// DonorSetupRequest is everything the automatic setup needs. The password goes
// to the script through stdin and is never part of the argument list.
type DonorSetupRequest struct {
	Host                         string
	SSHPort                      int
	User                         string
	Password                     string
	AwgPort                      int
	HostKey                      string
	AllowDisableDefaultUpstreams bool
}

// ErrDonorUnsupported means the installed MTProxyL has no donor tunnel yet.
var ErrDonorUnsupported = fmt.Errorf("установленный MTProxyL не умеет туннель до донора")

var (
	donorUserRe    = regexp.MustCompile(`^[a-z_][a-z0-9_.-]{0,31}$`)
	donorHostKeyRe = regexp.MustCompile(`^SHA256:[A-Za-z0-9+/]{43}$`)
	donorPubKeyRe  = regexp.MustCompile(`^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$`)
)

// ValidateDonorHost accepts a public IPv4 address only.
func ValidateDonorHost(host string) error {
	a, err := netip.ParseAddr(strings.TrimSpace(host))
	if err != nil || !a.Is4() || a.IsLoopback() || a.IsUnspecified() || a.IsMulticast() {
		return fmt.Errorf("нужен IPv4-адрес донора")
	}
	return nil
}

func validDonorPort(p int) bool { return p >= 1 && p <= 65535 }

// ValidateDonorKey checks an AmneziaWG public key (base64 of 32 bytes).
func ValidateDonorKey(key string) error {
	if !donorPubKeyRe.MatchString(key) {
		return fmt.Errorf("это не ключ AmneziaWG: 44 символа base64")
	}
	return nil
}

func (c *Client) DonorGetStatus(ctx context.Context) (*DonorStatus, error) {
	out, err := c.run(ctx, "donor", "status", "--json")
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrDonorUnsupported
		}
		return nil, err
	}
	return parseDonorStatus(out)
}

func parseDonorStatus(out string) (*DonorStatus, error) {
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrDonorUnsupported
	}
	var st DonorStatus
	if err := json.Unmarshal([]byte(line), &st); err != nil {
		return nil, fmt.Errorf("parse donor status: %w", err)
	}
	return &st, nil
}

// DonorHostKeys scans the donor's SSH host keys so the user can confirm one
// before any password leaves the server.
func (c *Client) DonorHostKeys(ctx context.Context, host string, port int) ([]DonorHostKey, error) {
	if err := ValidateDonorHost(host); err != nil {
		return nil, err
	}
	if !validDonorPort(port) {
		return nil, fmt.Errorf("неверный порт SSH")
	}
	out, err := c.run(ctx, "donor", "hostkey", strings.TrimSpace(host), strconv.Itoa(port), "--json")
	if err != nil {
		return nil, err
	}
	var res struct {
		Fingerprints []DonorHostKey `json:"fingerprints"`
	}
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &res); err != nil {
		return nil, fmt.Errorf("не удалось прочитать ключи хоста донора")
	}
	if len(res.Fingerprints) == 0 {
		return nil, fmt.Errorf("донор не отдал ключи хоста")
	}
	return res.Fingerprints, nil
}

func (r DonorSetupRequest) args() ([]string, error) {
	if err := ValidateDonorHost(r.Host); err != nil {
		return nil, err
	}
	if !validDonorPort(r.SSHPort) {
		return nil, fmt.Errorf("неверный порт SSH")
	}
	if !donorUserRe.MatchString(r.User) {
		return nil, fmt.Errorf("неверное имя пользователя")
	}
	if r.AwgPort != 0 && !validDonorPort(r.AwgPort) {
		return nil, fmt.Errorf("неверный порт AmneziaWG")
	}
	if !donorHostKeyRe.MatchString(r.HostKey) {
		return nil, fmt.Errorf("подтвердите ключ хоста донора")
	}
	if strings.ContainsAny(r.Password, "\r\n") || len(r.Password) > 512 {
		return nil, fmt.Errorf("пароль не должен содержать перевод строки")
	}
	args := []string{"donor", "setup", strings.TrimSpace(r.Host),
		"--ssh-port", strconv.Itoa(r.SSHPort), "--user", r.User}
	if r.AwgPort != 0 {
		args = append(args, "--awg-port", strconv.Itoa(r.AwgPort))
	}
	args = append(args, "--host-key", r.HostKey, "--password-stdin", "--yes")
	if r.AllowDisableDefaultUpstreams {
		args = append(args, "--allow-disable-default-upstreams")
	}
	return args, nil
}

// Validate reports an input error before any operation starts.
func (r DonorSetupRequest) Validate() error {
	_, err := r.args()
	return err
}

// DonorSetup installs the tunnel on both sides and routes the engine through it.
func (c *Client) DonorSetup(ctx context.Context, r DonorSetupRequest) (string, error) {
	args, err := r.args()
	if err != nil {
		return "", err
	}
	out, err := c.runWithStdin(ctx, r.Password+"\n", args...)
	return stripANSI(out), err
}

// DonorManual prepares the script for the donor and returns it with the
// instructions printed by the command.
func (c *Client) DonorManual(ctx context.Context, host string, awgPort int) (string, string, error) {
	if err := ValidateDonorHost(host); err != nil {
		return "", "", err
	}
	args := []string{"donor", "manual", strings.TrimSpace(host)}
	if awgPort != 0 {
		if !validDonorPort(awgPort) {
			return "", "", fmt.Errorf("неверный порт AmneziaWG")
		}
		args = append(args, strconv.Itoa(awgPort))
	}
	out, err := c.run(ctx, args...)
	if err != nil {
		return stripANSI(out), "", err
	}
	script, err := c.DonorManualScript(ctx)
	return stripANSI(out), script, err
}

func (c *Client) DonorManualScript(ctx context.Context) (string, error) {
	return c.run(ctx, "donor", "manual-script")
}

func (c *Client) DonorFinish(ctx context.Context, key string, allowDisableDefaultUpstreams bool) (string, error) {
	key = strings.TrimSpace(key)
	if err := ValidateDonorKey(key); err != nil {
		return "", err
	}
	args := []string{"donor", "finish", key, "--yes"}
	if allowDisableDefaultUpstreams {
		args = append(args, "--allow-disable-default-upstreams")
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

func (c *Client) DonorCheck(ctx context.Context) (*DonorStatus, error) {
	out, err := c.run(ctx, "donor", "check", "--json")
	if err != nil {
		return nil, err
	}
	return parseDonorStatus(out)
}

func (c *Client) DonorEnable(ctx context.Context, allowDisableDefaultUpstreams bool) (string, error) {
	args := []string{"donor", "on", "--yes"}
	if allowDisableDefaultUpstreams {
		args = append(args, "--allow-disable-default-upstreams")
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

func (c *Client) DonorDisable(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "donor", "off")
	return stripANSI(out), err
}

// DonorRemove deletes the tunnel here and, when remote is set, on the donor too.
func (c *Client) DonorRemove(ctx context.Context, remote bool, password string) (string, error) {
	if !remote {
		out, err := c.run(ctx, "donor", "remove", "--yes")
		return stripANSI(out), err
	}
	if strings.ContainsAny(password, "\r\n") || len(password) > 512 {
		return "", fmt.Errorf("пароль не должен содержать перевод строки")
	}
	out, err := c.runWithStdin(ctx, password+"\n", "donor", "remove", "--yes", "--remote", "--password-stdin")
	return stripANSI(out), err
}
