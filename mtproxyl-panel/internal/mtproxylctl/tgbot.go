package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Телеграм-бот ставится и настраивается тем же CLI, что и всё остальное:
// панель только показывает его состояние и дёргает подкоманды. Своего доступа
// к /opt/mtproxyl-tgbot у неё нет — каталог принадлежит боту и закрыт.

// ErrTgbotUnsupported means the installed MTProxyL predates the bot.
var ErrTgbotUnsupported = errors.New("установленный MTProxyL не умеет управлять телеграм-ботом")

// TgbotConfig is the bot's own config.json without the token.
type TgbotConfig struct {
	Admins     []int64         `json:"admins"`
	Notify     map[string]bool `json:"notify"`
	Intervals  map[string]int  `json:"intervals"`
	Autobackup struct {
		Enabled  bool   `json:"enabled"`
		Time     string `json:"time"`
		SendFile bool   `json:"send_file"`
	} `json:"autobackup"`
	// Proxy is the bot's SOCKS5 route to Telegram; empty means direct.
	Proxy    string `json:"proxy"`
	HasToken bool   `json:"has_token"`
}

// TgbotStatus is `mtproxyl tgbot status --json`.
type TgbotStatus struct {
	Installed  bool        `json:"installed"`
	Configured bool        `json:"configured"`
	Active     bool        `json:"active"`
	Enabled    bool        `json:"enabled"`
	Dir        string      `json:"dir"`
	Service    string      `json:"service"`
	Config     TgbotConfig `json:"config"`
}

// tokenRe is BotFather's format: numeric id, colon, opaque secret.
var tokenRe = regexp.MustCompile(`^[0-9]{5,}:[A-Za-z0-9_-]{30,}$`)

// ValidateTgbotToken checks the shape before the token reaches the CLI —
// authenticity Telegram confirms itself, and the script asks it.
func ValidateTgbotToken(token string) error {
	if !tokenRe.MatchString(token) {
		return fmt.Errorf("не похоже на токен: ожидается 1234567890:AAH…")
	}
	return nil
}

func (c *Client) TgbotStatus(ctx context.Context) (*TgbotStatus, error) {
	out, err := c.run(ctx, "tgbot", "status", "--json")
	if err != nil {
		if unsupportedCommand(out, err) {
			return nil, ErrTgbotUnsupported
		}
		return nil, err
	}
	line := firstJSONLine(out)
	if line == "" {
		return nil, ErrTgbotUnsupported
	}
	var st TgbotStatus
	if err := json.Unmarshal([]byte(line), &st); err != nil {
		return nil, fmt.Errorf("parse tgbot status: %w", err)
	}
	return &st, nil
}

// TgbotLogs returns the last lines of the bot's service journal.
func (c *Client) TgbotLogs(ctx context.Context, lines int) (string, error) {
	if lines <= 0 || lines > 500 {
		lines = 100
	}
	out, err := c.run(ctx, "tgbot", "logs", "--json", strconv.Itoa(lines))
	if err != nil {
		if unsupportedCommand(out, err) {
			return "", ErrTgbotUnsupported
		}
		return "", err
	}
	var payload struct {
		Lines string `json:"lines"`
	}
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &payload); err != nil {
		return "", fmt.Errorf("parse tgbot logs: %w", err)
	}
	return payload.Lines, nil
}

// TgbotInstall installs or reinstalls the bot. An empty token means «keep the
// one already configured» — that is how a reinstall over a working bot works.
func (c *Client) TgbotInstall(ctx context.Context, token string, admin int64) (string, error) {
	args := []string{"tgbot", "install"}
	if token != "" {
		if err := ValidateTgbotToken(token); err != nil {
			return "", err
		}
		if admin <= 0 {
			return "", fmt.Errorf("нужен числовой Telegram ID администратора")
		}
		args = append(args, "--token", token, "--admin", strconv.FormatInt(admin, 10))
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

// TgbotService runs start, stop, restart or update.
func (c *Client) TgbotService(ctx context.Context, action string) (string, error) {
	switch action {
	case "start", "stop", "restart", "update":
	default:
		return "", fmt.Errorf("неизвестное действие: %s", action)
	}
	out, err := c.run(ctx, "tgbot", action)
	return stripANSI(out), err
}

func (c *Client) TgbotUninstall(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "tgbot", "uninstall", "--yes")
	return stripANSI(out), err
}

func (c *Client) TgbotAdmin(ctx context.Context, id int64, add bool) (string, error) {
	if id <= 0 {
		return "", fmt.Errorf("нужен числовой Telegram ID")
	}
	action := "admin-rm"
	if add {
		action = "admin-add"
	}
	out, err := c.run(ctx, "tgbot", action, strconv.FormatInt(id, 10))
	return stripANSI(out), err
}

// tgbotSettable lists the keys the panel may change, with how to check them.
var tgbotSettable = map[string]string{
	"notify.availability":    "bool",
	"notify.dc":              "bool",
	"notify.proxy":           "bool",
	"notify.limits":          "bool",
	"notify.backup":          "bool",
	"intervals.availability": "minutes",
	"intervals.dc":           "minutes",
	"intervals.proxy":        "minutes",
	"intervals.limits":       "minutes",
	"autobackup.enabled":     "bool",
	"autobackup.send_file":   "bool",
	"autobackup.time":        "time",
	"proxy":                  "proxy",
}

// proxyRe: локальный SOCKS5 для бота. Схему проверяем и здесь, и в bash —
// aiogram увидит её только при старте службы, и опечатка стоила бы падения.
var proxyRe = regexp.MustCompile(`^socks5h?://([^:/@\s]+(:[^@/\s]*)?@)?[A-Za-z0-9._-]+:[0-9]{1,5}$`)

var timeRe = regexp.MustCompile(`^([01]?[0-9]|2[0-3]):[0-5][0-9]$`)

// TgbotSet changes one bot setting. The near-side check keeps a typo from
// travelling through sudo just to be rejected by bash with a bare exit code.
func (c *Client) TgbotSet(ctx context.Context, key, value string) (string, error) {
	kind, ok := tgbotSettable[key]
	if !ok {
		return "", fmt.Errorf("настройка %q недоступна", key)
	}
	switch kind {
	case "bool":
		if value != "true" && value != "false" {
			return "", fmt.Errorf("ожидается true или false")
		}
	case "minutes":
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 1440 {
			return "", fmt.Errorf("ожидается число от 1 до 1440")
		}
	case "time":
		if !timeRe.MatchString(value) {
			return "", fmt.Errorf("ожидается время в формате ЧЧ:ММ")
		}
	case "proxy":
		// Пустое значение — «ходить напрямую», это штатный способ выключить.
		if value != "" && value != "off" && !proxyRe.MatchString(value) {
			return "", fmt.Errorf("ожидается socks5://[логин:пароль@]хост:порт")
		}
	}
	out, err := c.run(ctx, "tgbot", "set", key, value)
	return stripANSI(out), err
}

// TgbotTokenHint explains where to get a token — the panel shows it in the
// install form, and duplicating the wording in the frontend would let the two
// drift apart.
func TgbotTokenHint() string {
	return strings.Join([]string{
		"Откройте @BotFather в Telegram и отправьте /newbot",
		"Придумайте имя и username (должен заканчиваться на bot)",
		"BotFather пришлёт строку вида 1234567890:AAH… — это токен",
		"Свой Telegram ID подскажет @userinfobot",
	}, "\n")
}
