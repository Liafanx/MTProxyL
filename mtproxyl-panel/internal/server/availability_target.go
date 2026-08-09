package server

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// availabilityOverrideFile is where the operator's choice of what to check
// lives. Deliberately not the panel config: that file is hand-written TOML with
// comments, and rewriting it from a form would cost the comments.
const availabilityOverrideFile = "availability-target.json"

// AvailabilityOverride is what the operator typed on the «Доступность» page.
//
// Autodetection is right for the common setup and wrong for the ones it cannot
// see: a proxy behind a CDN, a second domain pointed at the same server, a port
// forwarded from another. An empty field means «determine automatically», so
// clearing the form restores the detected value rather than checking nothing.
type AvailabilityOverride struct {
	Host string `json:"host,omitempty"`
	Port uint16 `json:"port,omitempty"`
	SNI  string `json:"sni,omitempty"`
}

// availabilityOverrideStore persists the override across restarts.
type availabilityOverrideStore struct {
	mu   sync.RWMutex
	path string
	cur  AvailabilityOverride
}

func newAvailabilityOverrideStore(dataDir string) *availabilityOverrideStore {
	s := &availabilityOverrideStore{}
	if dataDir != "" {
		s.path = filepath.Join(dataDir, availabilityOverrideFile)
	}
	s.load()
	return s
}

func (s *availabilityOverrideStore) load() {
	if s.path == "" {
		return
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		return // нет файла — переопределения нет, это нормальный случай
	}
	var o AvailabilityOverride
	if err := json.Unmarshal(data, &o); err != nil {
		// Битый файл не должен мешать проверке работать: автоопределение
		// справится само, а операторская правка вернётся первым сохранением.
		return
	}
	s.mu.Lock()
	s.cur = o
	s.mu.Unlock()
}

func (s *availabilityOverrideStore) get() AvailabilityOverride {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cur
}

func (s *availabilityOverrideStore) set(o AvailabilityOverride) error {
	s.mu.Lock()
	s.cur = o
	s.mu.Unlock()

	if s.path == "" {
		return nil // без data_dir переопределение живёт до перезапуска
	}
	data, err := json.Marshal(o)
	if err != nil {
		return err
	}
	// Через временный файл: оборванная запись оставила бы обрезанный JSON,
	// и следующий старт молча вернулся бы к автоопределению.
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// hostPattern is a conservative hostname: labels of letters, digits and
// hyphens. Anything with a scheme, a slash, a colon or a space is a mistake
// worth reporting rather than passing on to the probe service.
var hostPattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$`)

// validateAvailabilityOverride rejects input that could only produce a
// confusing check result. Empty fields are valid — they mean «auto».
func validateAvailabilityOverride(o *AvailabilityOverride) error {
	o.Host = strings.TrimSpace(o.Host)
	o.SNI = strings.TrimSpace(o.SNI)

	if err := validateHostField(o.Host, "Адрес"); err != nil {
		return err
	}
	if err := validateHostField(o.SNI, "SNI"); err != nil {
		return err
	}
	return nil
}

func validateHostField(v, label string) error {
	if v == "" {
		return nil
	}
	if len(v) > 253 {
		return fmt.Errorf("%s: слишком длинное имя", label)
	}
	// IP-литерал — законная цель: у сервера может не быть домена вовсе.
	if net.ParseIP(v) != nil {
		return nil
	}
	if strings.Contains(v, "://") || strings.ContainsAny(v, "/ :?#@") {
		return fmt.Errorf("%s: нужно только имя хоста или IP, без схемы, порта и пути", label)
	}
	if !hostPattern.MatchString(v) {
		return fmt.Errorf("%s: %q не похоже на домен или IP", label, v)
	}
	return nil
}
