package mtproxylctl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// ErrEngineUnsupported means the installed MTProxyL predates `engine versions`.
var ErrEngineUnsupported = errors.New(
	"установленный MTProxyL не умеет отдавать версии движка — обновите его: mtproxyl update")

// EngineRelease is one published telemt release.
type EngineRelease struct {
	Tag  string `json:"tag"`
	Name string `json:"name"`
	Date string `json:"date"`
}

// EngineVersions is `mtproxyl engine versions`.
type EngineVersions struct {
	// Backend is docker or binary.
	Backend         string `json:"backend"`
	Current         string `json:"current"`
	Binary          bool   `json:"binary"`
	DockerAvailable bool   `json:"docker_available"`
	// Local lists versions already on disk: those roll back without network.
	Local    []string        `json:"local"`
	Releases []EngineRelease `json:"releases"`
}

type EngineCleanupCandidate struct {
	Reference string `json:"reference"`
	ID        string `json:"id"`
	Size      string `json:"size"`
}

type EngineCleanupPreview struct {
	Candidates []EngineCleanupCandidate `json:"candidates"`
}

func (c *Client) EngineCleanupPreview(ctx context.Context) (*EngineCleanupPreview, error) {
	out, err := c.run(ctx, "engine", "cleanup", "--json")
	if err != nil {
		return nil, err
	}
	var preview EngineCleanupPreview
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &preview); err != nil {
		return nil, fmt.Errorf("не удалось прочитать список очистки: обновите MTProxyL")
	}
	if preview.Candidates == nil {
		return nil, fmt.Errorf("установленный MTProxyL не возвращает список очистки")
	}
	return &preview, nil
}

func (c *Client) EngineCleanup(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "engine", "cleanup", "--yes")
	return stripANSI(out), err
}

// engineTagRe bounds what may travel to the CLI as a version argument. The tag
// goes as one argv element, but it also ends up in a URL and a file name.
var engineTagRe = regexp.MustCompile(`^v?[0-9A-Za-z][0-9A-Za-z._-]{0,39}$`)

// ValidateEngineTag rejects anything that is not a plausible version tag.
func ValidateEngineTag(tag string) error {
	t := strings.TrimSpace(tag)
	if t == "" {
		return fmt.Errorf("версия не указана")
	}
	if !engineTagRe.MatchString(t) {
		return fmt.Errorf("недопустимая версия: %s", tag)
	}
	return nil
}

// EngineVersions asks MTProxyL what is installed and what is published.
func (c *Client) EngineVersions(ctx context.Context) (*EngineVersions, error) {
	out, err := c.run(ctx, "engine", "versions")
	if err != nil {
		var ce *CommandError
		if errors.As(err, &ce) && strings.Contains(ce.Output, "Использование") {
			return nil, ErrEngineUnsupported
		}
		return nil, err
	}
	var v EngineVersions
	if err := json.Unmarshal([]byte(firstJSONLine(out)), &v); err != nil {
		// Не JSON — команда неизвестна и скрипт напечатал свою справку.
		return nil, ErrEngineUnsupported
	}
	return &v, nil
}

// EngineUpdate installs a published telemt version.
func (c *Client) EngineUpdate(ctx context.Context, tag string) (string, error) {
	if err := ValidateEngineTag(tag); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "engine", "update", strings.TrimSpace(tag))
	return stripANSI(out), err
}

// EngineRollback switches back to a version already on disk. An empty tag means
// "the previous one" and is the only form the binary carrier understands.
func (c *Client) EngineRollback(ctx context.Context, tag string) (string, error) {
	t := strings.TrimSpace(tag)
	if t == "" {
		out, err := c.run(ctx, "engine", "rollback", "--yes")
		return stripANSI(out), err
	}
	if err := ValidateEngineTag(t); err != nil {
		return "", err
	}
	out, err := c.run(ctx, "engine", "rollback", t)
	return stripANSI(out), err
}
