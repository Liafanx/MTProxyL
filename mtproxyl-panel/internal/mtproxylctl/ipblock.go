package mtproxylctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// IPBlockStatus is the output of `mtproxyl block status --json`.
type IPBlockStatus struct {
	Enabled     bool     `json:"enabled"`
	Action      string   `json:"action"`
	RulesActive bool     `json:"rules_active"`
	Count       int      `json:"count"`
	HitsTotal   int64    `json:"hits_total"`
	Entries     []string `json:"entries"`
}

// IPBlockHit is one accumulated per-address counter.
type IPBlockHit struct {
	Entry   string `json:"entry"`
	Packets int64  `json:"packets"`
	Bytes   int64  `json:"bytes"`
	First   string `json:"first"`
	Last    string `json:"last"`
}

// ipv4Re and ipv6Re bound what may reach the CLI as an argument. The entry
// travels as one argv element, never as a shell string, but MTProxyL stores it
// in a file, so the shape is checked on this side too.
var (
	ipv4Re = regexp.MustCompile(`^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(/(\d{1,2}))?$`)
	ipv6Re = regexp.MustCompile(`^[0-9a-fA-F:]+(/\d{1,3})?$`)
)

// ValidateBlockEntry accepts an IPv4/IPv6 address or CIDR and nothing else.
func ValidateBlockEntry(entry string) error {
	e := strings.TrimSpace(entry)
	if e == "" {
		return fmt.Errorf("пустая запись")
	}
	if len(e) > 64 {
		return fmt.Errorf("слишком длинная запись")
	}
	if m := ipv4Re.FindStringSubmatch(e); m != nil {
		for i := 1; i <= 4; i++ {
			n, err := strconv.Atoi(m[i])
			if err != nil || n > 255 {
				return fmt.Errorf("октет вне диапазона: %s", e)
			}
		}
		if m[6] != "" {
			n, err := strconv.Atoi(m[6])
			if err != nil || n > 32 {
				return fmt.Errorf("маска вне диапазона: %s", e)
			}
		}
		return nil
	}
	if strings.Contains(e, ":") && ipv6Re.MatchString(e) && !strings.Contains(e, ":::") {
		if i := strings.Index(e, "/"); i >= 0 {
			n, err := strconv.Atoi(e[i+1:])
			if err != nil || n > 128 {
				return fmt.Errorf("маска вне диапазона: %s", e)
			}
		}
		return nil
	}
	return fmt.Errorf("не адрес и не подсеть: %s", e)
}

// ValidateBlockComment keeps the free-text note free of anything that would
// break the on-disk list format.
func ValidateBlockComment(c string) error {
	if len(c) > 120 {
		return fmt.Errorf("комментарий длиннее 120 символов")
	}
	if strings.ContainsAny(c, "\n\r#") {
		return fmt.Errorf("комментарий не должен содержать перевод строки или #")
	}
	return nil
}

func (c *Client) IPBlockStatus(ctx context.Context) (*IPBlockStatus, error) {
	out, err := c.run(ctx, "block", "status", "--json")
	if err != nil {
		return nil, err
	}
	var st IPBlockStatus
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &st); err != nil {
		return nil, fmt.Errorf("parse block status: %w", err)
	}
	if st.Entries == nil {
		st.Entries = []string{}
	}
	return &st, nil
}

func (c *Client) IPBlockAdd(ctx context.Context, entry, comment string) (string, error) {
	args := []string{"block", "add", entry}
	if comment != "" {
		args = append(args, comment)
	}
	out, err := c.run(ctx, args...)
	return stripANSI(out), err
}

func (c *Client) IPBlockRemove(ctx context.Context, entry string) (string, error) {
	out, err := c.run(ctx, "block", "del", entry)
	return stripANSI(out), err
}

func (c *Client) IPBlockSetEnabled(ctx context.Context, on bool) (string, error) {
	verb := "off"
	if on {
		verb = "on"
	}
	out, err := c.run(ctx, "block", verb)
	return stripANSI(out), err
}

func (c *Client) IPBlockSetAction(ctx context.Context, action string) (string, error) {
	if action != "drop" && action != "reject" {
		return "", fmt.Errorf("действие: drop или reject")
	}
	out, err := c.run(ctx, "block", "action", action)
	return stripANSI(out), err
}

// IPBlockExport returns the on-disk list verbatim, comments included.
func (c *Client) IPBlockExport(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "block", "export")
	return stripANSI(out), err
}

// IPBlockImport replaces or appends the list from raw text in the same format.
func (c *Client) IPBlockImport(ctx context.Context, body, mode string) (string, error) {
	if mode != "append" {
		mode = "replace"
	}
	out, err := c.runWithStdin(ctx, body, "block", "import", "-", mode)
	return stripANSI(out), err
}

// IPBlockHits parses `mtproxyl block hits` into rows. The CLI prints a table
// for humans; the columns are fixed, so a field split is enough.
func (c *Client) IPBlockHits(ctx context.Context) ([]IPBlockHit, error) {
	out, err := c.run(ctx, "block", "hits", "--tsv")
	if err != nil {
		return nil, err
	}
	hits := []IPBlockHit{}
	for _, line := range strings.Split(stripANSI(out), "\n") {
		f := strings.Split(strings.TrimRight(line, "\r"), "\t")
		if len(f) < 5 || f[0] == "" {
			continue
		}
		p, _ := strconv.ParseInt(f[1], 10, 64)
		b, _ := strconv.ParseInt(f[2], 10, 64)
		hits = append(hits, IPBlockHit{Entry: f[0], Packets: p, Bytes: b, First: f[3], Last: f[4]})
	}
	return hits, nil
}
