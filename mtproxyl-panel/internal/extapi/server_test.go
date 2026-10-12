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
func (f *fakeCLI) Links(_ context.Context, l string) ([]string, error) {
	return []string{"tg://proxy?server=x&port=443&secret=" + f.users[l].Secret}, nil
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
	c, out := do(t, s, "POST", "/v1/users", `{"username":"bob","max_tcp_conns":5,"data_quota_bytes":1000,"rate_limit_down_bps":2000000,"enabled":false}`, key)
	if c != 201 {
		t.Fatalf("создание: %d %v", c, out)
	}
	u := f.users["bob"]
	if u.MaxConns != 5 || u.QuotaBytes != 1000 || u.RateDownBps != 2000000 || u.Enabled {
		t.Fatalf("лимиты не применены: %+v", u)
	}
	data := out["data"].(map[string]any)
	if data["links"] == nil || data["max_tcp_conns"].(float64) != 5 {
		t.Fatalf("ответ: %v", data)
	}

	// Частичная правка: остальные лимиты не обнуляются.
	if c, out := do(t, s, "PATCH", "/v1/users/bob", `{"max_unique_ips":3}`, key); c != 200 {
		t.Fatalf("правка: %d %v", c, out)
	}
	if u := f.users["bob"]; u.MaxIPs != 3 || u.MaxConns != 5 || u.QuotaBytes != 1000 {
		t.Fatalf("правка затёрла лимиты: %+v", u)
	}
	// Скорость правится отдельно от лимитов, второе направление сохраняется.
	if c, _ := do(t, s, "PATCH", "/v1/users/bob", `{"rate_limit_up_bps":500}`, key); c != 200 {
		t.Fatal("скорость")
	}
	if u := f.users["bob"]; u.RateUpBps != 500 || u.RateDownBps != 2000000 {
		t.Fatalf("скорость: %+v", u)
	}
	if c, _ := do(t, s, "PATCH", "/v1/users/bob", `{"username":"bobby"}`, key); c != 200 {
		t.Fatal("переименование")
	}
	if _, ok := f.users["bobby"]; !ok {
		t.Fatal("имя не сменилось")
	}
	if c, _ := do(t, s, "PATCH", "/v1/users/bobby", `{"secret":"x"}`, key); c != 400 {
		t.Fatal("секрет через PATCH должен отклоняться")
	}
	if c, _ := do(t, s, "PATCH", "/v1/users/bobby", `{"bogus":1}`, key); c != 400 {
		t.Fatal("неизвестное поле должно отклоняться")
	}
	if c, _ := do(t, s, "POST", "/v1/users", `{"username":"alice"}`, key); c != 409 {
		t.Fatal("дубликат должен давать 409")
	}
	if c, _ := do(t, s, "DELETE", "/v1/users/bobby", "", key); c != 200 {
		t.Fatal("удаление")
	}
	if c, _ := do(t, s, "DELETE", "/v1/users/bobby", "", key); c != 404 {
		t.Fatal("повторное удаление должно давать 404")
	}
	if c, _ := do(t, s, "GET", "/v1/users/..%2f", "", key); c != 400 && c != 404 {
		t.Fatalf("плохое имя: %d", c)
	}
}

// Клиенты шлют объект пользователя целиком: пустое или прежнее имя, тот же
// секрет и поля только для чтения не должны давать ошибку после правки.
func TestPatchFullObject(t *testing.T) {
	f := newFake()
	s := New(f, HashKey(key), nil, "t")
	body := `{"username":"","secret":"` + strings.Repeat("a", 32) + `","expiration_rfc3339":"2027-01-01","notes":"","created":1,"traffic":{"total_bytes":0},"links":[]}`
	if c, out := do(t, s, "PATCH", "/v1/users/alice", body, key); c != 200 {
		t.Fatalf("полный объект: %d %v", c, out)
	}
	if f.users["alice"].Expires != "2027-01-01" {
		t.Fatalf("срок не применён: %+v", f.users["alice"])
	}
	if c, _ := do(t, s, "PATCH", "/v1/users/alice", `{"username":"alice","max_tcp_conns":2}`, key); c != 200 {
		t.Fatal("прежнее имя")
	}
	// Плохое имя отклоняется до записи остальных полей.
	if c, _ := do(t, s, "PATCH", "/v1/users/alice", `{"username":"плохое","max_tcp_conns":9}`, key); c != 400 {
		t.Fatal("плохое имя должно отклоняться")
	}
	if f.users["alice"].MaxConns != 2 {
		t.Fatalf("правка прошла при плохом имени: %+v", f.users["alice"])
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
