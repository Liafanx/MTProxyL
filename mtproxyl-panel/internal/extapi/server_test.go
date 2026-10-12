package extapi

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

type fakeCLI struct {
	users map[string]*mtproxylctl.Secret
	calls []string
}

func newFake() *fakeCLI {
	return &fakeCLI{users: map[string]*mtproxylctl.Secret{
		"alice": {Label: "alice", Secret: strings.Repeat("a", 32), Enabled: true, Expires: "0"},
	}}
}

func (f *fakeCLI) ListSecrets(context.Context) ([]mtproxylctl.Secret, error) {
	out := []mtproxylctl.Secret{}
	for _, u := range f.users {
		out = append(out, *u)
	}
	return out, nil
}
func (f *fakeCLI) AddSecret(_ context.Context, l, s string) (string, error) {
	f.calls = append(f.calls, "add "+l)
	if _, ok := f.users[l]; ok {
		return "", &mtproxylctl.CommandError{Err: errors.New("exit 1"), Output: "[✗] Секрет '" + l + "' уже существует"}
	}
	if s == "" {
		s = strings.Repeat("b", 32)
	}
	f.users[l] = &mtproxylctl.Secret{Label: l, Secret: s, Enabled: true, Expires: "0"}
	return "", nil
}
func (f *fakeCLI) RemoveSecret(_ context.Context, l string) (string, error) {
	f.calls = append(f.calls, "remove "+l)
	if _, ok := f.users[l]; !ok {
		return "", &mtproxylctl.CommandError{Err: errors.New("exit 1"), Output: "[✗] Секрет '" + l + "' не найден"}
	}
	delete(f.users, l)
	return "", nil
}
func (f *fakeCLI) RotateSecret(_ context.Context, l string) (string, error) {
	f.users[l].Secret = strings.Repeat("c", 32)
	return "", nil
}
func (f *fakeCLI) ToggleSecret(_ context.Context, l string, en bool) (string, error) {
	f.calls = append(f.calls, "toggle "+l)
	f.users[l].Enabled = en
	return "", nil
}
func (f *fakeCLI) RenameSecret(_ context.Context, a, b string) (string, error) {
	u := f.users[a]
	delete(f.users, a)
	u.Label = b
	f.users[b] = u
	return "", nil
}
func (f *fakeCLI) SetLimitsFull(_ context.Context, l string, c, i, q int64, e string) (string, error) {
	f.calls = append(f.calls, "limits "+l)
	u := f.users[l]
	u.MaxConns, u.MaxIPs, u.QuotaBytes, u.Expires = int(c), int(i), q, e
	return "", nil
}
func (f *fakeCLI) SetSecretAdTag(_ context.Context, l, t string) (string, error) {
	f.users[l].AdTag = t
	return "", nil
}
func (f *fakeCLI) SetSecretRate(_ context.Context, l string, up, down int64) (string, error) {
	f.calls = append(f.calls, "rate "+l)
	f.users[l].RateUpBps, f.users[l].RateDownBps = up, down
	return "", nil
}
func (f *fakeCLI) ResetQuota(context.Context, string) (string, error)       { return "", nil }
func (f *fakeCLI) ResetUserTraffic(context.Context, string) (string, error) { return "", nil }

// Ссылки как у MTProxyL: ee с доменом example.com, dd и WEB.
func (f *fakeCLI) APIView(_ context.Context, l string) (*mtproxylctl.APIView, error) {
	v := &mtproxylctl.APIView{Links: map[string][]string{}, Live: map[string]mtproxylctl.EngineUser{}}
	for name, u := range f.users {
		if l != "" && name != l {
			continue
		}
		v.Links[name] = []string{
			"tg://proxy?server=x&port=443&secret=ee" + u.Secret + "6578616d706c652e636f6d",
			"tg://proxy?server=x&port=443&secret=ee" + u.Secret + "6f746865722e6f7267",
			"tg://proxy?server=x&port=443&secret=dd" + u.Secret,
			"tg://webproxy?server=web.x&secret=dd" + u.Secret,
		}
		v.Live[name] = mtproxylctl.EngineUser{Username: name, InRuntime: true, CurrentConnections: 2,
			ActiveUniqueIPs: 1, ActiveUniqueIPsList: []string{"192.0.2.1"}, TotalOctets: 42}
	}
	return v, nil
}
func (f *fakeCLI) RotateSecretTo(_ context.Context, l, s string) (string, error) {
	f.users[l].Secret = s
	return "", nil
}
func (f *fakeCLI) StatusRaw(context.Context) (json.RawMessage, error) {
	return json.RawMessage(`{"mode":"manager"}`), nil
}
func (f *fakeCLI) RestartProxy(context.Context) (string, error) { return "", nil }

const key = "test-key-0123456789"

func do(t *testing.T, s http.Handler, method, path, body, auth string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = "192.0.2.10:5555"
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestAuth(t *testing.T) {
	s := New(newFake(), HashKey(key), nil, "t")
	if c, _ := do(t, s, "GET", "/v1/health", "", ""); c != 401 {
		t.Fatalf("без ключа: %d", c)
	}
	if c, _ := do(t, s, "GET", "/v1/health", "", "wrong"); c != 401 {
		t.Fatalf("чужой ключ: %d", c)
	}
	if c, _ := do(t, s, "GET", "/v1/health", "", "Bearer "+key); c != 200 {
		t.Fatalf("Bearer: %d", c)
	}
	if c, _ := do(t, s, "GET", "/v1/health", "", key); c != 200 {
		t.Fatalf("голый ключ: %d", c)
	}
}

func TestAllowAndLockout(t *testing.T) {
	_, n, _ := net.ParseCIDR("10.0.0.0/8")
	s := New(newFake(), HashKey(key), []*net.IPNet{n}, "t")
	if c, _ := do(t, s, "GET", "/v1/health", "", key); c != 403 {
		t.Fatalf("адрес вне списка: %d", c)
	}
	s = New(newFake(), HashKey(key), nil, "t")
	s.fails["192.0.2.10"] = &failWindow{count: failLimit, since: nowForTest()}
	if c, _ := do(t, s, "GET", "/v1/health", "", key); c != 429 {
		t.Fatalf("после перебора: %d", c)
	}
}

func TestUserLifecycle(t *testing.T) {
	f := newFake()
	s := New(f, HashKey(key), nil, "t")
	c, out := do(t, s, "POST", "/v1/users", `{"username":"bob","max_tcp_conns":5,"data_quota_bytes":1000,"rate_limit_down_bps":2000000,"enabled":false,"unknown_field":1}`, key)
	if c != 201 {
		t.Fatalf("создание: %d %v", c, out)
	}
	u := f.users["bob"]
	if u.MaxConns != 5 || u.QuotaBytes != 1000 || u.RateDownBps != 2000000 || u.Enabled {
		t.Fatalf("лимиты не применены: %+v", u)
	}
	// CreateUserResponse telemt: {user, secret}.
	data := out["data"].(map[string]any)
	user := data["user"].(map[string]any)
	if data["secret"] != u.Secret || user["max_tcp_conns"].(float64) != 5 {
		t.Fatalf("ответ создания: %v", data)
	}
	if out["revision"] == nil {
		t.Fatal("нет revision")
	}

	// Частичная правка: остальные лимиты не обнуляются.
	if c, out := do(t, s, "PATCH", "/v1/users/bob", `{"max_unique_ips":3}`, key); c != 200 {
		t.Fatalf("правка: %d %v", c, out)
	}
	if u := f.users["bob"]; u.MaxIPs != 3 || u.MaxConns != 5 || u.QuotaBytes != 1000 {
		t.Fatalf("правка затёрла лимиты: %+v", u)
	}
	// null снимает ограничение, как JSON Merge Patch у telemt.
	if c, _ := do(t, s, "PATCH", "/v1/users/bob", `{"max_tcp_conns":null,"rate_limit_up_bps":500}`, key); c != 200 {
		t.Fatal("null")
	}
	if u := f.users["bob"]; u.MaxConns != 0 || u.MaxIPs != 3 || u.RateUpBps != 500 || u.RateDownBps != 2000000 {
		t.Fatalf("null/скорость: %+v", u)
	}
	if c, _ := do(t, s, "PATCH", "/v1/users/bob", `{"username":"bobby"}`, key); c != 200 {
		t.Fatal("переименование")
	}
	if _, ok := f.users["bobby"]; !ok {
		t.Fatal("имя не сменилось")
	}
	// secret в PATCH ставит этот секрет.
	if c, _ := do(t, s, "PATCH", "/v1/users/bobby", `{"secret":"`+strings.Repeat("d", 32)+`"}`, key); c != 200 || f.users["bobby"].Secret != strings.Repeat("d", 32) {
		t.Fatal("секрет через PATCH")
	}
	if c, _ := do(t, s, "PATCH", "/v1/users/bobby", `{"secret":"x"}`, key); c != 400 {
		t.Fatal("кривой секрет должен отклоняться")
	}
	if c, out := do(t, s, "POST", "/v1/users", `{"username":"alice"}`, key); c != 409 || out["error"].(map[string]any)["code"] != "user_exists" {
		t.Fatalf("дубликат: %d %v", c, out)
	}
	c, out = do(t, s, "POST", "/v1/users/bobby/rotate-secret", `{"secret":"`+strings.Repeat("e", 32)+`"}`, key)
	if c != 200 || out["data"].(map[string]any)["secret"] != strings.Repeat("e", 32) {
		t.Fatalf("rotate: %d %v", c, out)
	}
	c, out = do(t, s, "POST", "/v1/users/bobby/reset-quota", "", key)
	if c != 200 || out["data"].(map[string]any)["used_bytes"].(float64) != 0 {
		t.Fatalf("reset-quota: %v", out)
	}
	if c, out := do(t, s, "DELETE", "/v1/users/bobby", "", key); c != 200 || out["data"].(map[string]any)["in_runtime"] != false {
		t.Fatalf("удаление: %v", out)
	}
	if c, _ := do(t, s, "DELETE", "/v1/users/bobby", "", key); c != 404 {
		t.Fatal("повторное удаление должно давать 404")
	}
	if c, _ := do(t, s, "GET", "/v1/users/..%2f", "", key); c != 400 && c != 404 {
		t.Fatalf("плохое имя: %d", c)
	}
}

// Формат UserInfo telemt: null вместо «без ограничения», ссылки объектом,
// срок с +00:00, живые данные движка.
func TestUserInfoFormat(t *testing.T) {
	f := newFake()
	f.users["alice"].Expires = "2026-10-22T20:59:59Z"
	s := New(f, HashKey(key), nil, "t")
	c, out := do(t, s, "GET", "/v1/users/alice", "", key)
	if c != 200 {
		t.Fatalf("%d %v", c, out)
	}
	u := out["data"].(map[string]any)
	for _, k := range []string{"max_tcp_conns", "max_unique_ips", "data_quota_bytes", "user_ad_tag", "rate_limit_up_bps", "rate_limit_down_bps"} {
		if v, ok := u[k]; !ok || v != nil {
			t.Fatalf("%s: ждали null, получили %v", k, v)
		}
	}
	if u["expiration_rfc3339"] != "2026-10-22T20:59:59+00:00" {
		t.Fatalf("срок: %v", u["expiration_rfc3339"])
	}
	if u["current_connections"].(float64) != 2 || u["total_octets"].(float64) != 42 || u["in_runtime"] != true {
		t.Fatalf("живые данные: %v", u)
	}
	links := u["links"].(map[string]any)
	if len(links["tls"].([]any)) != 2 || len(links["secure"].([]any)) != 1 || len(links["classic"].([]any)) != 0 || len(links["web"].([]any)) != 1 {
		t.Fatalf("ссылки: %v", links)
	}
	td := links["tls_domains"].([]any)
	if len(td) != 1 || td[0].(map[string]any)["domain"] != "other.org" {
		t.Fatalf("tls_domains: %v", td)
	}
	// Список — массив UserInfo, отсортированный по имени.
	do(t, s, "POST", "/v1/users", `{"username":"aaa"}`, key)
	_, out = do(t, s, "GET", "/v1/users", "", key)
	list := out["data"].([]any)
	if len(list) != 2 || list[0].(map[string]any)["username"] != "aaa" || list[1].(map[string]any)["links"] == nil {
		t.Fatalf("список: %v", list)
	}
}

// If-Match как у telemt: чужая ревизия даёт 409 и ничего не меняет.
func TestIfMatch(t *testing.T) {
	f := newFake()
	s := New(f, HashKey(key), nil, "t")
	_, out := do(t, s, "GET", "/v1/users/alice", "", key)
	rev := out["revision"].(string)
	req := httptest.NewRequest("PATCH", "/v1/users/alice", strings.NewReader(`{"max_tcp_conns":7}`))
	req.Header.Set("Authorization", key)
	req.Header.Set("If-Match", "deadbeef")
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != 409 || f.users["alice"].MaxConns != 0 {
		t.Fatalf("чужая ревизия: %d", rec.Code)
	}
	req = httptest.NewRequest("PATCH", "/v1/users/alice", strings.NewReader(`{"max_tcp_conns":7}`))
	req.Header.Set("Authorization", key)
	req.Header.Set("If-Match", `"`+rev+`"`)
	rec = httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if rec.Code != 200 || f.users["alice"].MaxConns != 7 {
		t.Fatalf("своя ревизия: %d", rec.Code)
	}
}

func TestCreateRollsBackOnBadLimits(t *testing.T) {
	f := newFake()
	s := New(&failingLimits{f}, HashKey(key), nil, "t")
	if c, _ := do(t, s, "POST", "/v1/users", `{"username":"eve","max_tcp_conns":1}`, key); c == 201 {
		t.Fatal("должна быть ошибка")
	}
	if _, ok := f.users["eve"]; ok {
		t.Fatal("наполовину созданный пользователь остался")
	}
}

type failingLimits struct{ *fakeCLI }

func (f *failingLimits) SetLimitsFull(context.Context, string, int64, int64, int64, string) (string, error) {
	return "", &mtproxylctl.CommandError{Err: errors.New("exit 1"), Output: "[✗] Макс. соединений: число"}
}

func nowForTest() time.Time { return time.Now() }
