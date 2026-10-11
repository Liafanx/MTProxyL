// Package extapi — внешний API управления MTProxyL. В режиме Manager API
// движка пользователей не пишет (конфиг собирает MTProxyL), поэтому
// пользователи и лимиты идут через CLI, как у панели. Имена полей — как у
// API telemt, чтобы внешним проектам не держать две схемы.
package extapi

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

// CLI — то, что API берёт у MTProxyL. Интерфейс, чтобы тесты обходились без bash.
type CLI interface {
	ListSecrets(ctx context.Context) ([]mtproxylctl.Secret, error)
	AddSecret(ctx context.Context, label, secret string) (string, error)
	RemoveSecret(ctx context.Context, label string) (string, error)
	RotateSecret(ctx context.Context, label string) (string, error)
	ToggleSecret(ctx context.Context, label string, enable bool) (string, error)
	RenameSecret(ctx context.Context, from, to string) (string, error)
	SetLimitsFull(ctx context.Context, label string, conns, ips, quota int64, expires string) (string, error)
	SetSecretAdTag(ctx context.Context, label, tag string) (string, error)
	SetSecretRate(ctx context.Context, label string, up, down int64) (string, error)
	ResetQuota(ctx context.Context, label string) (string, error)
	ResetUserTraffic(ctx context.Context, label string) (string, error)
	Links(ctx context.Context, label string) ([]string, error)
	StatusRaw(ctx context.Context) (json.RawMessage, error)
	RestartProxy(ctx context.Context) (string, error)
}

type Server struct {
	cli     CLI
	keyHash [32]byte
	allow   []*net.IPNet
	version string
	// Команды CLI пишут secrets.conf и конфиг движка — по одной за раз.
	write sync.Mutex
	mux   *http.ServeMux

	failMu sync.Mutex
	fails  map[string]*failWindow
}

type failWindow struct {
	count int
	since time.Time
}

const (
	maxBody      = 64 << 10
	failLimit    = 10
	failWindowTT = time.Minute
)

// New собирает сервер. keyHash — SHA-256 ключа: сам ключ на диске не лежит.
func New(cli CLI, keyHash [32]byte, allow []*net.IPNet, version string) *Server {
	s := &Server{cli: cli, keyHash: keyHash, allow: allow, version: version, fails: map[string]*failWindow{}}
	m := http.NewServeMux()
	m.HandleFunc("GET /v1/health", s.health)
	m.HandleFunc("GET /v1/status", s.status)
	m.HandleFunc("POST /v1/proxy/restart", s.restart)
	m.HandleFunc("GET /v1/users", s.listUsers)
	m.HandleFunc("POST /v1/users", s.createUser)
	m.HandleFunc("GET /v1/users/{username}", s.getUser)
	m.HandleFunc("PATCH /v1/users/{username}", s.patchUser)
	m.HandleFunc("DELETE /v1/users/{username}", s.deleteUser)
	m.HandleFunc("POST /v1/users/{username}/enable", s.toggle(true))
	m.HandleFunc("POST /v1/users/{username}/disable", s.toggle(false))
	m.HandleFunc("POST /v1/users/{username}/rotate-secret", s.rotate)
	m.HandleFunc("POST /v1/users/{username}/reset-quota", s.resetQuota)
	m.HandleFunc("POST /v1/users/{username}/reset-traffic", s.resetTraffic)
	m.HandleFunc("GET /v1/users/{username}/links", s.links)
	s.mux = m
	return s
}

// HashKey — то же преобразование, что делает `mtproxyl api key`.
func HashKey(key string) [32]byte { return sha256.Sum256([]byte(key)) }

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !s.allowed(ip) {
		writeErr(w, http.StatusForbidden, "forbidden", "адрес не в списке разрешённых")
		return
	}
	if s.tooManyFails(ip) {
		writeErr(w, http.StatusTooManyRequests, "too_many_attempts", "слишком много неверных ключей, подождите минуту")
		return
	}
	if !s.authorized(r) {
		s.recordFail(ip)
		// Пауза делает перебор ключа бессмысленным даже без лимита.
		time.Sleep(300 * time.Millisecond)
		writeErr(w, http.StatusUnauthorized, "unauthorized", "нужен заголовок Authorization с ключом API")
		return
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	}
	s.mux.ServeHTTP(w, r)
}

func (s *Server) authorized(r *http.Request) bool {
	h := strings.TrimSpace(r.Header.Get("Authorization"))
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		h = strings.TrimSpace(h[7:])
	}
	if h == "" {
		return false
	}
	got := sha256.Sum256([]byte(h))
	return subtle.ConstantTimeCompare(got[:], s.keyHash[:]) == 1
}

func (s *Server) allowed(ip net.IP) bool {
	if len(s.allow) == 0 {
		return true
	}
	if ip == nil {
		return false
	}
	for _, n := range s.allow {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

func (s *Server) tooManyFails(ip net.IP) bool {
	s.failMu.Lock()
	defer s.failMu.Unlock()
	f := s.fails[ip.String()]
	if f == nil {
		return false
	}
	if time.Since(f.since) > failWindowTT {
		delete(s.fails, ip.String())
		return false
	}
	return f.count >= failLimit
}

func (s *Server) recordFail(ip net.IP) {
	s.failMu.Lock()
	defer s.failMu.Unlock()
	if len(s.fails) > 10000 {
		s.fails = map[string]*failWindow{}
	}
	f := s.fails[ip.String()]
	if f == nil || time.Since(f.since) > failWindowTT {
		f = &failWindow{since: time.Now()}
		s.fails[ip.String()] = f
	}
	f.count++
}

func clientIP(r *http.Request) net.IP {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return net.ParseIP(host)
}

// ── Ответы ────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	// Ссылки tg:// содержат «&» — без экранирования их можно копировать как есть.
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func writeOK(w http.ResponseWriter, code int, data any) {
	writeJSON(w, code, map[string]any{"ok": true, "data": data})
}

func writeErr(w http.ResponseWriter, code int, kind, msg string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": map[string]string{"code": kind, "message": msg}})
}

// cliErr переводит отказ CLI в код HTTP по его же сообщению.
func cliErr(w http.ResponseWriter, err error) {
	msg := err.Error()
	var ce *mtproxylctl.CommandError
	if errors.As(err, &ce) && ce.Output != "" {
		msg = ce.Output
	}
	msg = strings.TrimSpace(strings.TrimPrefix(msg, "[✗]"))
	low := strings.ToLower(msg)
	switch {
	case strings.Contains(low, "не найден"):
		writeErr(w, http.StatusNotFound, "not_found", msg)
	case strings.Contains(low, "уже существует"), strings.Contains(low, "уже есть"):
		writeErr(w, http.StatusConflict, "already_exists", msg)
	case strings.Contains(low, "последний"):
		writeErr(w, http.StatusConflict, "conflict", msg)
	case ce == nil:
		writeErr(w, http.StatusBadRequest, "bad_request", msg)
	case strings.Contains(strings.ToLower(err.Error()), "timed out"):
		writeErr(w, http.StatusGatewayTimeout, "timeout", msg)
	default:
		// MTProxyL отказал сам: неверное значение, выключенный API движка и т.п.
		writeErr(w, http.StatusUnprocessableEntity, "rejected", msg)
	}
}

func decode(r *http.Request, v any) error {
	if r.Body == nil {
		return nil
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return fmt.Errorf("тело запроса: %v", err)
	}
	return nil
}

// ── Модель пользователя ───────────────────────────────────────

type Traffic struct {
	In    int64 `json:"in_bytes"`
	Out   int64 `json:"out_bytes"`
	Total int64 `json:"total_bytes"`
}

type User struct {
	Username         string   `json:"username"`
	Secret           string   `json:"secret"`
	Enabled          bool     `json:"enabled"`
	MaxTCPConns      int      `json:"max_tcp_conns"`
	MaxUniqueIPs     int      `json:"max_unique_ips"`
	DataQuotaBytes   int64    `json:"data_quota_bytes"`
	Expiration       string   `json:"expiration_rfc3339"`
	UserAdTag        string   `json:"user_ad_tag"`
	RateLimitUpBps   int64    `json:"rate_limit_up_bps"`
	RateLimitDownBps int64    `json:"rate_limit_down_bps"`
	Notes            string   `json:"notes"`
	Created          int64    `json:"created"`
	Traffic          Traffic  `json:"traffic"`
	Links            []string `json:"links,omitempty"`
}

func fromSecret(s mtproxylctl.Secret) User {
	exp := s.Expires
	if exp == "0" {
		exp = ""
	}
	return User{
		Username: s.Label, Secret: s.Secret, Enabled: s.Enabled,
		MaxTCPConns: s.MaxConns, MaxUniqueIPs: s.MaxIPs, DataQuotaBytes: s.QuotaBytes,
		Expiration: exp, UserAdTag: s.AdTag,
		RateLimitUpBps: s.RateUpBps, RateLimitDownBps: s.RateDownBps,
		Notes: s.Notes, Created: s.Created,
		Traffic: Traffic{In: s.TotalIn, Out: s.TotalOut, Total: s.TotalBytes},
	}
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$`)

func (s *Server) findUser(ctx context.Context, name string) (*User, error) {
	list, err := s.cli.ListSecrets(ctx)
	if err != nil {
		return nil, err
	}
	for _, sec := range list {
		if sec.Label == name {
			u := fromSecret(sec)
			return &u, nil
		}
	}
	return nil, nil
}

// userWithLinks — состояние пользователя после операции, со ссылками.
func (s *Server) userWithLinks(w http.ResponseWriter, r *http.Request, name string, code int) {
	u, err := s.findUser(r.Context(), name)
	if err != nil {
		cliErr(w, err)
		return
	}
	if u == nil {
		writeErr(w, http.StatusNotFound, "not_found", "пользователь "+name+" не найден")
		return
	}
	if links, err := s.cli.Links(r.Context(), name); err == nil {
		u.Links = links
	}
	writeOK(w, code, u)
}

func pathUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("username")
	if !usernameRe.MatchString(name) {
		writeErr(w, http.StatusBadRequest, "bad_request", "имя: латиница, цифры, дефис и подчёркивание, до 32 символов")
		return "", false
	}
	return name, true
}

// ── Обработчики ───────────────────────────────────────────────

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeOK(w, http.StatusOK, map[string]string{"status": "ok", "api_version": s.version})
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	raw, err := s.cli.StatusRaw(r.Context())
	if err != nil {
		cliErr(w, err)
		return
	}
	writeOK(w, http.StatusOK, raw)
}

func (s *Server) restart(w http.ResponseWriter, r *http.Request) {
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.RestartProxy(r.Context()); err != nil {
		cliErr(w, err)
		return
	}
	writeOK(w, http.StatusOK, map[string]bool{"restarted": true})
}

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	list, err := s.cli.ListSecrets(r.Context())
	if err != nil {
		cliErr(w, err)
		return
	}
	out := make([]User, 0, len(list))
	withLinks := r.URL.Query().Get("links") == "true" || r.URL.Query().Get("links") == "1"
	for _, sec := range list {
		u := fromSecret(sec)
		if withLinks {
			if links, err := s.cli.Links(r.Context(), u.Username); err == nil {
				u.Links = links
			}
		}
		out = append(out, u)
	}
	writeOK(w, http.StatusOK, out)
}

func (s *Server) getUser(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.userWithLinks(w, r, name, http.StatusOK)
}

// Поля запроса — указатели: отсутствующее поле значит «не менять».
type userFields struct {
	Username         *string `json:"username"`
	Secret           *string `json:"secret"`
	Enabled          *bool   `json:"enabled"`
	MaxTCPConns      *int64  `json:"max_tcp_conns"`
	MaxUniqueIPs     *int64  `json:"max_unique_ips"`
	DataQuotaBytes   *int64  `json:"data_quota_bytes"`
	Expiration       *string `json:"expiration_rfc3339"`
	UserAdTag        *string `json:"user_ad_tag"`
	RateLimitUpBps   *int64  `json:"rate_limit_up_bps"`
	RateLimitDownBps *int64  `json:"rate_limit_down_bps"`
}

func (f *userFields) touchesLimits() bool {
	return f.MaxTCPConns != nil || f.MaxUniqueIPs != nil || f.DataQuotaBytes != nil || f.Expiration != nil
}

func (f *userFields) touchesRate() bool { return f.RateLimitUpBps != nil || f.RateLimitDownBps != nil }

// apply доводит пользователя до запрошенного: лимиты, метка, скорость,
// включённость. Незатронутые поля берутся из текущего состояния.
func (s *Server) apply(ctx context.Context, cur *User, f *userFields) error {
	if f.touchesLimits() {
		conns, ips, quota, exp := int64(cur.MaxTCPConns), int64(cur.MaxUniqueIPs), cur.DataQuotaBytes, cur.Expiration
		if f.MaxTCPConns != nil {
			conns = *f.MaxTCPConns
		}
		if f.MaxUniqueIPs != nil {
			ips = *f.MaxUniqueIPs
		}
		if f.DataQuotaBytes != nil {
			quota = *f.DataQuotaBytes
		}
		if f.Expiration != nil {
			exp = *f.Expiration
		}
		if _, err := s.cli.SetLimitsFull(ctx, cur.Username, conns, ips, quota, exp); err != nil {
			return err
		}
	}
	if f.touchesRate() {
		up, down := cur.RateLimitUpBps, cur.RateLimitDownBps
		if f.RateLimitUpBps != nil {
			up = *f.RateLimitUpBps
		}
		if f.RateLimitDownBps != nil {
			down = *f.RateLimitDownBps
		}
		if _, err := s.cli.SetSecretRate(ctx, cur.Username, up, down); err != nil {
			return err
		}
	}
	if f.UserAdTag != nil && *f.UserAdTag != cur.UserAdTag {
		if _, err := s.cli.SetSecretAdTag(ctx, cur.Username, *f.UserAdTag); err != nil {
			return err
		}
	}
	if f.Enabled != nil && *f.Enabled != cur.Enabled {
		if _, err := s.cli.ToggleSecret(ctx, cur.Username, *f.Enabled); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	var f userFields
	if err := decode(r, &f); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if f.Username == nil || !usernameRe.MatchString(*f.Username) {
		writeErr(w, http.StatusBadRequest, "bad_request", "username: латиница, цифры, дефис и подчёркивание, до 32 символов")
		return
	}
	name := *f.Username
	secret := ""
	if f.Secret != nil {
		secret = *f.Secret
	}
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.AddSecret(r.Context(), name, secret); err != nil {
		cliErr(w, err)
		return
	}
	cur, err := s.findUser(r.Context(), name)
	if err != nil || cur == nil {
		writeErr(w, http.StatusInternalServerError, "internal_error", "пользователь создан, но не прочитан")
		return
	}
	if err := s.apply(r.Context(), cur, &f); err != nil {
		// Наполовину настроенный пользователь хуже отсутствующего.
		_, _ = s.cli.RemoveSecret(r.Context(), name)
		cliErr(w, err)
		return
	}
	s.userWithLinks(w, r, name, http.StatusCreated)
}

func (s *Server) patchUser(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	var f userFields
	if err := decode(r, &f); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if f.Secret != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "секрет меняется через POST /v1/users/{username}/rotate-secret")
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	cur, err := s.findUser(r.Context(), name)
	if err != nil {
		cliErr(w, err)
		return
	}
	if cur == nil {
		writeErr(w, http.StatusNotFound, "not_found", "пользователь "+name+" не найден")
		return
	}
	if err := s.apply(r.Context(), cur, &f); err != nil {
		cliErr(w, err)
		return
	}
	// Переименование последним: если другая правка не прошла, имя прежнее.
	if f.Username != nil && *f.Username != name {
		if !usernameRe.MatchString(*f.Username) {
			writeErr(w, http.StatusBadRequest, "bad_request", "username: латиница, цифры, дефис и подчёркивание, до 32 символов")
			return
		}
		if _, err := s.cli.RenameSecret(r.Context(), name, *f.Username); err != nil {
			cliErr(w, err)
			return
		}
		name = *f.Username
	}
	s.userWithLinks(w, r, name, http.StatusOK)
}

func (s *Server) deleteUser(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.RemoveSecret(r.Context(), name); err != nil {
		cliErr(w, err)
		return
	}
	writeOK(w, http.StatusOK, map[string]string{"username": name, "deleted": "true"})
}

func (s *Server) toggle(enable bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name, ok := pathUser(w, r)
		if !ok {
			return
		}
		s.write.Lock()
		defer s.write.Unlock()
		if _, err := s.cli.ToggleSecret(r.Context(), name, enable); err != nil {
			cliErr(w, err)
			return
		}
		s.userWithLinks(w, r, name, http.StatusOK)
	}
}

func (s *Server) rotate(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.RotateSecret(r.Context(), name); err != nil {
		cliErr(w, err)
		return
	}
	s.userWithLinks(w, r, name, http.StatusOK)
}

func (s *Server) resetQuota(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.ResetQuota(r.Context(), name); err != nil {
		cliErr(w, err)
		return
	}
	writeOK(w, http.StatusOK, map[string]string{"username": name, "quota": "reset"})
}

func (s *Server) resetTraffic(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.ResetUserTraffic(r.Context(), name); err != nil {
		cliErr(w, err)
		return
	}
	writeOK(w, http.StatusOK, map[string]string{"username": name, "traffic": "reset"})
}

func (s *Server) links(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	links, err := s.cli.Links(r.Context(), name)
	if err != nil {
		cliErr(w, err)
		return
	}
	writeOK(w, http.StatusOK, map[string]any{"username": name, "links": links})
}

// LogRequests — короткий журнал: метод, путь, код, длительность. Без тела и
// заголовков: в них ключ и секреты.
func LogRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %s %d %s", clientIP(r), r.Method, r.URL.Path, rec.code, time.Since(start).Round(time.Millisecond))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}
