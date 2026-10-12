// Package extapi — внешний API управления MTProxyL. В режиме Manager API
// движка пользователей не пишет (конфиг собирает MTProxyL), поэтому
// пользователи и лимиты идут через CLI, как у панели. Имена полей — как у
// API telemt, чтобы внешним проектам не держать две схемы.
package extapi

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
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
	APIView(ctx context.Context, label string) (*mtproxylctl.APIView, error)
	RotateSecretTo(ctx context.Context, label, secret string) (string, error)
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

// writeRev — конверт telemt с revision: её можно вернуть в If-Match.
func writeRev(w http.ResponseWriter, code int, data any, rev string) {
	if rev == "" {
		writeOK(w, code, data)
		return
	}
	writeJSON(w, code, map[string]any{"ok": true, "data": data, "revision": rev})
}

var requestID atomic.Int64

func writeErr(w http.ResponseWriter, code int, kind, msg string) {
	writeJSON(w, code, map[string]any{
		"ok":         false,
		"error":      map[string]string{"code": kind, "message": msg},
		"request_id": requestID.Add(1),
	})
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
		writeErr(w, http.StatusConflict, "user_exists", msg)
	case strings.Contains(low, "последний"):
		writeErr(w, http.StatusConflict, "last_user_forbidden", msg)
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
	// Незнакомые поля пропускаем, как telemt: клиент может прислать объект
	// пользователя целиком.
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return fmt.Errorf("тело запроса: %v", err)
	}
	return nil
}

// ── Модель пользователя ───────────────────────────────────────
// Ответы повторяют контракт API telemt (UserInfo, CreateUserResponse и т.д.):
// клиент, написанный под telemt, работает с MTProxyL без правок. Поля сверх
// контракта (secret, notes, created, traffic, links.web) клиенты telemt
// пропускают.

type Traffic struct {
	In    int64 `json:"in_bytes"`
	Out   int64 `json:"out_bytes"`
	Total int64 `json:"total_bytes"`
}

// rec — пользователь, как его хранит MTProxyL: 0 и "" значат «без ограничения».
type rec struct {
	Username         string
	Secret           string
	Enabled          bool
	MaxTCPConns      int64
	MaxUniqueIPs     int64
	DataQuotaBytes   int64
	Expiration       string
	UserAdTag        string
	RateLimitUpBps   int64
	RateLimitDownBps int64
	Notes            string
	Created          int64
	Traffic          Traffic
}

func fromSecret(s mtproxylctl.Secret) rec {
	exp := s.Expires
	if exp == "0" {
		exp = ""
	}
	return rec{
		Username: s.Label, Secret: s.Secret, Enabled: s.Enabled,
		MaxTCPConns: int64(s.MaxConns), MaxUniqueIPs: int64(s.MaxIPs), DataQuotaBytes: s.QuotaBytes,
		Expiration: exp, UserAdTag: s.AdTag,
		RateLimitUpBps: s.RateUpBps, RateLimitDownBps: s.RateDownBps,
		Notes: s.Notes, Created: s.Created,
		Traffic: Traffic{In: s.TotalIn, Out: s.TotalOut, Total: s.TotalBytes},
	}
}

type TLSDomainLink struct {
	Domain string `json:"domain"`
	Link   string `json:"link"`
}

// UserLinks — как у telemt; web — ссылки tg://webproxy, у telemt их нет.
type UserLinks struct {
	Classic    []string        `json:"classic"`
	Secure     []string        `json:"secure"`
	TLS        []string        `json:"tls"`
	TLSDomains []TLSDomainLink `json:"tls_domains"`
	Web        []string        `json:"web"`
}

// UserInfo — представление пользователя из API telemt.
type UserInfo struct {
	Username            string    `json:"username"`
	Enabled             bool      `json:"enabled"`
	InRuntime           bool      `json:"in_runtime"`
	UserAdTag           *string   `json:"user_ad_tag"`
	MaxTCPConns         *int64    `json:"max_tcp_conns"`
	Expiration          *string   `json:"expiration_rfc3339"`
	DataQuotaBytes      *int64    `json:"data_quota_bytes"`
	RateLimitUpBps      *int64    `json:"rate_limit_up_bps"`
	RateLimitDownBps    *int64    `json:"rate_limit_down_bps"`
	MaxUniqueIPs        *int64    `json:"max_unique_ips"`
	CurrentConnections  int64     `json:"current_connections"`
	ActiveUniqueIPs     int       `json:"active_unique_ips"`
	ActiveUniqueIPsList []string  `json:"active_unique_ips_list"`
	RecentUniqueIPs     int       `json:"recent_unique_ips"`
	RecentUniqueIPsList []string  `json:"recent_unique_ips_list"`
	TotalOctets         int64     `json:"total_octets"`
	Links               UserLinks `json:"links"`
	// Сверх контракта telemt.
	Secret  string  `json:"secret"`
	Notes   string  `json:"notes"`
	Created int64   `json:"created"`
	Traffic Traffic `json:"traffic"`
}

func nz(v int64) *int64 {
	if v <= 0 {
		return nil
	}
	return &v
}

func ns(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

// telemtTime приводит срок к виду, в котором его отдаёт telemt
// (chrono to_rfc3339): UTC со смещением +00:00.
func telemtTime(v string) *string {
	if v == "" {
		return nil
	}
	layouts := []string{time.RFC3339Nano, "2006-01-02"}
	for _, l := range layouts {
		if t, err := time.Parse(l, v); err == nil {
			out := t.UTC().Format("2006-01-02T15:04:05.999999999") + "+00:00"
			return &out
		}
	}
	return &v
}

// splitLinks раскладывает ссылки по видам, как telemt: classic — голый
// секрет, secure — dd, tls — ee с доменом, tls_domains — дополнительные домены.
func splitLinks(links []string) UserLinks {
	out := UserLinks{Classic: []string{}, Secure: []string{}, TLS: []string{}, TLSDomains: []TLSDomainLink{}, Web: []string{}}
	first := ""
	for _, l := range links {
		if strings.HasPrefix(l, "tg://webproxy") || strings.HasPrefix(l, "https://t.me/webproxy") {
			out.Web = append(out.Web, l)
			continue
		}
		u, err := url.Parse(l)
		if err != nil {
			continue
		}
		sec := strings.ToLower(u.Query().Get("secret"))
		switch {
		case strings.HasPrefix(sec, "ee") && len(sec) > 34:
			out.TLS = append(out.TLS, l)
			dom := ""
			if b, err := hex.DecodeString(sec[34:]); err == nil {
				dom = string(b)
			}
			if first == "" {
				first = dom
			} else if dom != "" && dom != first {
				out.TLSDomains = append(out.TLSDomains, TLSDomainLink{Domain: dom, Link: l})
			}
		case strings.HasPrefix(sec, "dd") && len(sec) == 34:
			out.Secure = append(out.Secure, l)
		case len(sec) == 32:
			out.Classic = append(out.Classic, l)
		}
	}
	return out
}

func toInfo(r rec, v *mtproxylctl.APIView) UserInfo {
	u := UserInfo{
		Username: r.Username, Enabled: r.Enabled, InRuntime: r.Enabled,
		UserAdTag: ns(r.UserAdTag), MaxTCPConns: nz(r.MaxTCPConns), Expiration: telemtTime(r.Expiration),
		DataQuotaBytes: nz(r.DataQuotaBytes), RateLimitUpBps: nz(r.RateLimitUpBps),
		RateLimitDownBps: nz(r.RateLimitDownBps), MaxUniqueIPs: nz(r.MaxUniqueIPs),
		ActiveUniqueIPsList: []string{}, RecentUniqueIPsList: []string{},
		TotalOctets: r.Traffic.Total,
		Links:       splitLinks(nil),
		Secret:      r.Secret, Notes: r.Notes, Created: r.Created, Traffic: r.Traffic,
	}
	if v == nil {
		return u
	}
	u.Links = splitLinks(v.Links[r.Username])
	if live, ok := v.Live[r.Username]; ok {
		u.InRuntime = live.InRuntime
		u.CurrentConnections = live.CurrentConnections
		u.ActiveUniqueIPs = live.ActiveUniqueIPs
		u.RecentUniqueIPs = live.RecentUniqueIPs
		u.TotalOctets = live.TotalOctets
		if live.ActiveUniqueIPsList != nil {
			u.ActiveUniqueIPsList = live.ActiveUniqueIPsList
		}
		if live.RecentUniqueIPsList != nil {
			u.RecentUniqueIPsList = live.RecentUniqueIPsList
		}
	} else if len(v.Live) > 0 {
		u.InRuntime = false
	}
	return u
}

// revisionOf — отпечаток настроек пользователей, аналог revision у telemt:
// по нему клиент делает If-Match. Трафик в него не входит — он меняется сам.
func revisionOf(list []mtproxylctl.Secret) string {
	h := sha256.New()
	for _, s := range list {
		fmt.Fprintf(h, "%s|%s|%t|%d|%d|%d|%s|%s|%d|%d\n", s.Label, s.Secret, s.Enabled,
			s.MaxConns, s.MaxIPs, s.QuotaBytes, s.Expires, s.AdTag, s.RateUpBps, s.RateDownBps)
	}
	return hex.EncodeToString(h.Sum(nil))
}

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$`)

const usernameRule = "username: латиница, цифры, дефис и подчёркивание, до 32 символов, первый — буква или цифра"

func (s *Server) findUser(ctx context.Context, name string) (*rec, string, error) {
	list, err := s.cli.ListSecrets(ctx)
	if err != nil {
		return nil, "", err
	}
	rev := revisionOf(list)
	for _, sec := range list {
		if sec.Label == name {
			u := fromSecret(sec)
			return &u, rev, nil
		}
	}
	return nil, rev, nil
}

// checkRevision — If-Match как у telemt: несовпадение даёт 409.
func checkRevision(w http.ResponseWriter, r *http.Request, rev string) bool {
	want := strings.Trim(strings.TrimSpace(r.Header.Get("If-Match")), `"`)
	if want == "" || want == rev {
		return true
	}
	writeErr(w, http.StatusConflict, "revision_conflict", "конфигурация изменилась: перечитайте пользователя и повторите")
	return false
}

// logViewErr — без api-view ссылки и живые данные пусты; причина обычно в
// правах sudo от прошлой версии, её видно только в журнале.
func logViewErr(err error) {
	log.Printf("api-view: %v (ссылки пусты; права обновит: mtproxyl api update)", err)
}

// info — пользователь после операции в виде UserInfo и текущая ревизия.
func (s *Server) info(ctx context.Context, name string) (*UserInfo, string, error) {
	list, view, err := s.snapshot(ctx, name)
	if err != nil {
		return nil, "", err
	}
	rev := revisionOf(list)
	for _, sec := range list {
		if sec.Label == name {
			i := toInfo(fromSecret(sec), view)
			return &i, rev, nil
		}
	}
	return nil, rev, nil
}

// snapshot — список пользователей и ссылки одним запуском скрипта: каждый
// запуск — это sudo и загрузка MTProxyL. Скрипт старше 1.7.3 список в
// api-view не кладёт — тогда отдельный secret list.
func (s *Server) snapshot(ctx context.Context, label string) ([]mtproxylctl.Secret, *mtproxylctl.APIView, error) {
	view, err := s.cli.APIView(ctx, label)
	if err != nil {
		logViewErr(err)
		view = nil
	}
	if view != nil && view.Users != nil {
		return view.Users, view, nil
	}
	list, err := s.cli.ListSecrets(ctx)
	return list, view, err
}

func (s *Server) writeUser(w http.ResponseWriter, r *http.Request, name string, code int, wrap func(*UserInfo) any) {
	u, rev, err := s.info(r.Context(), name)
	if err != nil {
		cliErr(w, err)
		return
	}
	if u == nil {
		writeErr(w, http.StatusNotFound, "not_found", "пользователь "+name+" не найден")
		return
	}
	var data any = u
	if wrap != nil {
		data = wrap(u)
	}
	writeRev(w, code, data, rev)
}

func pathUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("username")
	if !usernameRe.MatchString(name) {
		writeErr(w, http.StatusNotFound, "not_found", "пользователь "+name+" не найден")
		return "", false
	}
	return name, true
}

// ── Обработчики ───────────────────────────────────────────────

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeOK(w, http.StatusOK, map[string]any{"status": "ok", "read_only": false, "api_version": s.version})
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
	list, view, err := s.snapshot(r.Context(), "")
	if err != nil {
		cliErr(w, err)
		return
	}
	out := make([]UserInfo, 0, len(list))
	for _, sec := range list {
		out = append(out, toInfo(fromSecret(sec), view))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Username < out[j].Username })
	writeRev(w, http.StatusOK, out, revisionOf(list))
}

func (s *Server) getUser(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.writeUser(w, r, name, http.StatusOK, nil)
}

// opt — поле JSON Merge Patch: Set — поле прислали, Null — прислали null.
type opt[T any] struct {
	Set  bool
	Null bool
	V    T
}

func (o *opt[T]) UnmarshalJSON(b []byte) error {
	o.Set = true
	if string(b) == "null" {
		o.Null = true
		return nil
	}
	return json.Unmarshal(b, &o.V)
}

// userReq — CreateUserRequest и PatchUserRequest telemt; username в PATCH —
// переименование (у telemt его нет).
type userReq struct {
	Username         opt[string] `json:"username"`
	Secret           opt[string] `json:"secret"`
	Enabled          opt[bool]   `json:"enabled"`
	MaxTCPConns      opt[int64]  `json:"max_tcp_conns"`
	MaxUniqueIPs     opt[int64]  `json:"max_unique_ips"`
	DataQuotaBytes   opt[int64]  `json:"data_quota_bytes"`
	Expiration       opt[string] `json:"expiration_rfc3339"`
	UserAdTag        opt[string] `json:"user_ad_tag"`
	RateLimitUpBps   opt[int64]  `json:"rate_limit_up_bps"`
	RateLimitDownBps opt[int64]  `json:"rate_limit_down_bps"`
}

func (f *userReq) validate() error {
	for name, o := range map[string]opt[int64]{
		"max_tcp_conns": f.MaxTCPConns, "max_unique_ips": f.MaxUniqueIPs, "data_quota_bytes": f.DataQuotaBytes,
		"rate_limit_up_bps": f.RateLimitUpBps, "rate_limit_down_bps": f.RateLimitDownBps,
	} {
		if o.Set && !o.Null && o.V < 0 {
			return fmt.Errorf("%s: не может быть отрицательным", name)
		}
	}
	if f.Expiration.Set && !f.Expiration.Null && f.Expiration.V != "" {
		if _, err := time.Parse(time.RFC3339Nano, f.Expiration.V); err != nil {
			if _, err2 := time.Parse("2006-01-02", f.Expiration.V); err2 != nil {
				return fmt.Errorf("expiration_rfc3339 must be valid RFC3339")
			}
		}
	}
	if f.UserAdTag.Set && !f.UserAdTag.Null && f.UserAdTag.V != "" && !hex32Re.MatchString(f.UserAdTag.V) {
		return fmt.Errorf("user_ad_tag: ровно 32 шестнадцатеричных символа")
	}
	if f.Secret.Set && !f.Secret.Null && f.Secret.V != "" && !hex32Re.MatchString(f.Secret.V) {
		return fmt.Errorf("secret: ровно 32 шестнадцатеричных символа")
	}
	return nil
}

var hex32Re = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)

func pick64(o opt[int64], cur int64) int64 {
	if !o.Set {
		return cur
	}
	if o.Null {
		return 0
	}
	return o.V
}

func pickStr(o opt[string], cur string) string {
	if !o.Set {
		return cur
	}
	if o.Null {
		return ""
	}
	return o.V
}

// apply доводит пользователя до запрошенного. Незатронутые поля берутся из
// текущего состояния, null снимает ограничение.
func (s *Server) apply(ctx context.Context, cur *rec, f *userReq) error {
	if f.MaxTCPConns.Set || f.MaxUniqueIPs.Set || f.DataQuotaBytes.Set || f.Expiration.Set {
		if _, err := s.cli.SetLimitsFull(ctx, cur.Username,
			pick64(f.MaxTCPConns, cur.MaxTCPConns), pick64(f.MaxUniqueIPs, cur.MaxUniqueIPs),
			pick64(f.DataQuotaBytes, cur.DataQuotaBytes), pickStr(f.Expiration, cur.Expiration)); err != nil {
			return err
		}
	}
	if f.RateLimitUpBps.Set || f.RateLimitDownBps.Set {
		if _, err := s.cli.SetSecretRate(ctx, cur.Username,
			pick64(f.RateLimitUpBps, cur.RateLimitUpBps), pick64(f.RateLimitDownBps, cur.RateLimitDownBps)); err != nil {
			return err
		}
	}
	if tag := pickStr(f.UserAdTag, cur.UserAdTag); f.UserAdTag.Set && !strings.EqualFold(tag, cur.UserAdTag) {
		if _, err := s.cli.SetSecretAdTag(ctx, cur.Username, tag); err != nil {
			return err
		}
	}
	// enabled: null у telemt тоже значит «включён».
	if f.Enabled.Set {
		want := f.Enabled.Null || f.Enabled.V
		if want != cur.Enabled {
			if _, err := s.cli.ToggleSecret(ctx, cur.Username, want); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	var f userReq
	if err := decode(r, &f); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if f.Username.Null || !usernameRe.MatchString(f.Username.V) {
		writeErr(w, http.StatusBadRequest, "bad_request", usernameRule)
		return
	}
	if err := f.validate(); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	name := f.Username.V
	secret := pickStr(f.Secret, "")
	s.write.Lock()
	defer s.write.Unlock()
	if _, err := s.cli.AddSecret(r.Context(), name, strings.ToLower(secret)); err != nil {
		cliErr(w, err)
		return
	}
	cur, _, err := s.findUser(r.Context(), name)
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
	s.writeUser(w, r, name, http.StatusCreated, withSecret)
}

// withSecret — CreateUserResponse telemt: {user, secret}.
func withSecret(u *UserInfo) any {
	return map[string]any{"user": u, "secret": u.Secret}
}

func (s *Server) patchUser(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	var f userReq
	if err := decode(r, &f); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := f.validate(); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	// Пустое, null или прежнее имя — не переименование: так шлют клиенты,
	// отправляющие объект пользователя целиком.
	rename := ""
	if f.Username.Set && !f.Username.Null && f.Username.V != "" && f.Username.V != name {
		if !usernameRe.MatchString(f.Username.V) {
			writeErr(w, http.StatusBadRequest, "bad_request", usernameRule)
			return
		}
		rename = f.Username.V
	}
	s.write.Lock()
	defer s.write.Unlock()
	cur, rev, err := s.findUser(r.Context(), name)
	if err != nil {
		cliErr(w, err)
		return
	}
	if cur == nil {
		writeErr(w, http.StatusNotFound, "not_found", "пользователь "+name+" не найден")
		return
	}
	if !checkRevision(w, r, rev) {
		return
	}
	if err := s.apply(r.Context(), cur, &f); err != nil {
		cliErr(w, err)
		return
	}
	// secret в PATCH ставит этот секрет, как у telemt.
	if sec := pickStr(f.Secret, ""); sec != "" && !strings.EqualFold(sec, cur.Secret) {
		if _, err := s.cli.RotateSecretTo(r.Context(), name, sec); err != nil {
			cliErr(w, err)
			return
		}
	}
	// Переименование последним: если другая правка не прошла, имя прежнее.
	if rename != "" {
		if _, err := s.cli.RenameSecret(r.Context(), name, rename); err != nil {
			cliErr(w, err)
			return
		}
		name = rename
	}
	s.writeUser(w, r, name, http.StatusOK, nil)
}

// guardRev — If-Match для операций без тела.
func (s *Server) guardRev(w http.ResponseWriter, r *http.Request) bool {
	if r.Header.Get("If-Match") == "" {
		return true
	}
	list, err := s.cli.ListSecrets(r.Context())
	if err != nil {
		cliErr(w, err)
		return false
	}
	return checkRevision(w, r, revisionOf(list))
}

func (s *Server) deleteUser(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	if !s.guardRev(w, r) {
		return
	}
	if _, err := s.cli.RemoveSecret(r.Context(), name); err != nil {
		cliErr(w, err)
		return
	}
	rev := ""
	if list, err := s.cli.ListSecrets(r.Context()); err == nil {
		rev = revisionOf(list)
	}
	writeRev(w, http.StatusOK, map[string]any{"username": name, "in_runtime": false}, rev)
}

func (s *Server) toggle(enable bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name, ok := pathUser(w, r)
		if !ok {
			return
		}
		s.write.Lock()
		defer s.write.Unlock()
		if !s.guardRev(w, r) {
			return
		}
		if _, err := s.cli.ToggleSecret(r.Context(), name, enable); err != nil {
			cliErr(w, err)
			return
		}
		s.writeUser(w, r, name, http.StatusOK, nil)
	}
}

func (s *Server) rotate(w http.ResponseWriter, r *http.Request) {
	name, ok := pathUser(w, r)
	if !ok {
		return
	}
	var f struct {
		Secret string `json:"secret"`
	}
	if err := decode(r, &f); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if f.Secret != "" && !hex32Re.MatchString(f.Secret) {
		writeErr(w, http.StatusBadRequest, "bad_request", "secret: ровно 32 шестнадцатеричных символа")
		return
	}
	s.write.Lock()
	defer s.write.Unlock()
	if !s.guardRev(w, r) {
		return
	}
	var err error
	if f.Secret != "" {
		_, err = s.cli.RotateSecretTo(r.Context(), name, f.Secret)
	} else {
		_, err = s.cli.RotateSecret(r.Context(), name)
	}
	if err != nil {
		cliErr(w, err)
		return
	}
	s.writeUser(w, r, name, http.StatusOK, withSecret)
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
	writeOK(w, http.StatusOK, map[string]any{"username": name, "used_bytes": 0, "last_reset_epoch_secs": time.Now().Unix()})
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
	s.writeUser(w, r, name, http.StatusOK, func(u *UserInfo) any {
		return map[string]any{"username": u.Username, "links": u.Links}
	})
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
