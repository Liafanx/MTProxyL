package server

import (
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

func TestAPIEndpointMismatch(t *testing.T) {
	cases := []struct {
		name    string
		url     string
		st      *mtproxylctl.ModeStatus
		wantSub string // "" — предупреждения быть не должно
	}{
		{
			name: "порты совпадают — молчим",
			url:  "http://127.0.0.1:9091",
			st:   &mtproxylctl.ModeStatus{Mode: "manager", APIPort: 9091, APIEnabled: true},
		},
		{
			name:    "движок режима на другом порту",
			url:     "http://127.0.0.1:9091",
			st:      &mtproxylctl.ModeStatus{Mode: "reanimator", APIPort: 9099, APIEnabled: true, EngineConfig: "/etc/telemt/telemt.toml"},
			wantSub: "9099",
		},
		{
			name:    "API выключен в конфиге режима",
			url:     "http://127.0.0.1:9091",
			st:      &mtproxylctl.ModeStatus{Mode: "manager", APIPort: 9091, APIEnabled: false, EngineConfig: "/opt/mtproxyl/mtproxy/config.toml"},
			wantSub: "выключен",
		},
		{
			name: "порт движка неизвестен — не гадаем",
			url:  "http://127.0.0.1:9091",
			st:   &mtproxylctl.ModeStatus{Mode: "manager", APIPort: 0, APIEnabled: true},
		},
		{
			name: "url без порта и без схемы — не ругаемся зря",
			url:  "127.0.0.1",
			st:   &mtproxylctl.ModeStatus{Mode: "manager", APIPort: 9091, APIEnabled: true},
		},
		{
			name: "статус не прочитался",
			url:  "http://127.0.0.1:9091",
			st:   nil,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := apiEndpointMismatch(tc.url, tc.st)
			if tc.wantSub == "" {
				if got != "" {
					t.Fatalf("ожидалась тишина, получено: %q", got)
				}
				return
			}
			if !strings.Contains(got, tc.wantSub) {
				t.Fatalf("нет %q в сообщении: %q", tc.wantSub, got)
			}
			t.Logf("%s", got)
		})
	}
}

func TestPortOf(t *testing.T) {
	cases := map[string]int{
		"http://127.0.0.1:9091": 9091,
		"https://example.com":   443,
		"http://example.com":    80,
		"example.com:1234":      0, // без схемы url.Parse не даёт хоста
		"":                      0,
	}
	for in, want := range cases {
		if got := portOf(in); got != want {
			t.Errorf("portOf(%q) = %d, ожидалось %d", in, got, want)
		}
	}
}

// Конфиг, который MTProxyL генерирует в режиме менеджера, секции [server.api]
// не содержит — движок берёт своё умолчание enabled = true. Панель не должна
// на этом основании объявлять API выключенным: ровно так и появлялось ложное
// предупреждение «REST API выключен» на нормальной установке.
func TestManagerDefaultAPIIsNotReportedDisabled(t *testing.T) {
	st := &mtproxylctl.ModeStatus{
		Mode:         mtproxylctl.ModeManager,
		APIPort:      9091,
		APIEnabled:   true, // то, что теперь отдаёт mode --json без [server.api]
		EngineConfig: "/opt/mtproxyl/mtproxy/config.toml",
	}
	if got := apiEndpointMismatch("http://127.0.0.1:9091", st); got != "" {
		t.Fatalf("ожидалась тишина, получено: %q", got)
	}
}
