package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestValidateSetting(t *testing.T) {
	ok := [][2]string{
		{"PROXY_PORT", "8443"},
		{"PROXY_DOMAIN", "example.com"},
		{"AD_TAG", ""}, // очистка — законное значение
		{"MASKING_ENABLED", "false"},
		{"UNKNOWN_SNI_ACTION", "reject_handshake"},
		{"CUSTOM_IP", "203.0.113.10"},
		{"PROXY_API_PORT", "9091"},
	}
	for _, c := range ok {
		if err := ValidateSetting(c[0], c[1]); err != nil {
			t.Errorf("%s=%q отвергнуто: %s", c[0], c[1], err)
		}
	}

	bad := map[string][2]string{
		"ключ в нижнем регистре": {"proxy_port", "8443"},
		"ключ с путём":           {"../etc", "1"},
		"пустой ключ":            {"", "1"},
		"значение с флагом":      {"PROXY_DOMAIN", "-rf"},
		"перевод строки":         {"PROXY_DOMAIN", "a\nb"},
		"кавычка":                {"PROXY_DOMAIN", `a"b`},
		"пробел":                 {"PROXY_DOMAIN", "a b"},
		"точка с запятой":        {"PROXY_DOMAIN", "a;id"},
		"вертикальная черта":     {"PROXY_DOMAIN", "a|b"},
		"подстановка":            {"PROXY_DOMAIN", "$(id)"},
	}
	for name, c := range bad {
		if err := ValidateSetting(c[0], c[1]); err == nil {
			t.Errorf("%s: %s=%q должно отвергаться", name, c[0], c[1])
		}
	}
}

// Панель должна получать список и уметь изменить значение через тот же путь,
// каким это делает CLI.
func TestSettingsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "settings")
	if err := os.WriteFile(store, []byte("mask\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	script := filepath.Join(dir, "mtproxyl.sh")
	body := `#!/bin/bash
if [ "$1" = settings ] && [ "$2" = list ]; then
  printf '[{"key":"UNKNOWN_SNI_ACTION","validator":"enum:mask,drop","description":"Чужой SNI","value":"%s"}]\n' "$(cat ` + store + `)"
  exit 0
fi
if [ "$1" = settings ] && [ "$2" = set ]; then
  case "$4" in mask|drop) printf '%s' "$4" > ` + store + `; echo "[OK] $3 = $4"; exit 0 ;; esac
  echo "[X] недопустимое значение" >&2; exit 1
fi
exit 1
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})
	ctx := context.Background()

	list, err := c.Settings(ctx)
	if err != nil {
		t.Fatalf("чтение не удалось: %s", err)
	}
	if len(list) != 1 || list[0].Value != "mask" {
		t.Fatalf("неожиданный список: %+v", list)
	}

	if _, err := c.SetSetting(ctx, "UNKNOWN_SNI_ACTION", "drop"); err != nil {
		t.Fatalf("запись не удалась: %s", err)
	}
	list, _ = c.Settings(ctx)
	if list[0].Value != "drop" {
		t.Fatalf("значение не изменилось: %q", list[0].Value)
	}

	// Отказ CLI должен доходить до панели вместе с его собственным сообщением.
	_, err = c.SetSetting(ctx, "UNKNOWN_SNI_ACTION", "reject_handshake")
	if err == nil {
		t.Fatal("ожидалась ошибка от CLI")
	}
	if !strings.Contains(err.Error(), "недопустимое значение") {
		t.Fatalf("сообщение CLI потеряно: %s", err)
	}
}
