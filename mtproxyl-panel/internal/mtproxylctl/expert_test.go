package mtproxylctl

import (
	"context"
	"strings"
	"testing"
)

func TestValidateExpertParam(t *testing.T) {
	good := []struct{ section, key, value string }{
		{"general", "config_strict", "true"},
		{"general.links", "prefer_ipv6", "false"},
		{"censorship.tls_fetch", "enabled", "true"},
		{"censorship", "tls_domain", "www.example.com"},
		{"server.api", "listen", "0.0.0.0:9091"},
		{"timeouts", "client_handshake", "15"},
		{"logging", "level", "info"},
	}
	for _, c := range good {
		if err := ValidateExpertParam(c.section, c.key, c.value); err != nil {
			t.Errorf("ValidateExpertParam(%q,%q,%q) = %v, want nil", c.section, c.key, c.value, err)
		}
	}

	// Every field becomes an argument to a sudo-invoked command.
	bad := []struct{ section, key, value string }{
		{"", "k", "v"},
		{"general", "", "v"},
		{"General", "k", "v"},   // uppercase section
		{"general", "Key", "v"}, // uppercase key
		{"general; id", "k", "v"},
		{"general", "k; id", "v"},
		{"general", "k", "v; id"},
		{"general", "k", "$(id)"},
		{"general", "k", "`id`"},
		{"general", "k", "a b"},
		{"general", "k", "a\nb"},
		{"general", "k", "--flag"},
		{"general", "k", "a|b"},
		{"../etc", "k", "v"},
		{"general.", "k", "v"}, // trailing dot
		{".general", "k", "v"}, // leading dot
	}
	for _, c := range bad {
		if err := ValidateExpertParam(c.section, c.key, c.value); err == nil {
			t.Errorf("ValidateExpertParam(%q,%q,%q) = nil, want error", c.section, c.key, c.value)
		}
	}
}

func TestSetExpertParamRejectsEmptyValue(t *testing.T) {
	c := newStubClient(t)
	if _, err := c.SetExpertParam(context.Background(), "general", "config_strict", ""); err == nil {
		t.Error("empty value accepted")
	}
}

func TestSuperExpertWriteRejectsEmpty(t *testing.T) {
	c := newStubClient(t)
	for _, content := range []string{"", "   ", "\n\t\n"} {
		if _, err := c.SuperExpertWrite(context.Background(), content); err == nil {
			t.Errorf("empty config %q accepted", content)
		}
	}
}

// The engine config is piped rather than passed as an argument; this pins that
// stdin actually reaches the command.
func TestRunWithStdinPipesContent(t *testing.T) {
	c := newStubClient(t)
	out, err := c.runWithStdin(context.Background(), "hello-from-stdin\n", "superexpert", "write")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "hello-from-stdin") {
		t.Errorf("stdin did not reach the command, got %q", out)
	}
}

// Списочные параметры (string[] в каталоге MTProxyL) вводятся как список через
// запятую — скобки и кавычки добавляет применение override'а.
func TestExpertValueAllowsCommaSeparatedLists(t *testing.T) {
	ok := []string{
		"127.0.0.1/32,::1/128",
		"127.0.0.0/8",
		"",
		"10.0.0.0/8,192.168.0.0/16",
	}
	for _, v := range ok {
		if err := ValidateExpertParam("server.api", "whitelist", v); err != nil {
			t.Errorf("значение %q отвергнуто: %s", v, err)
		}
	}
}

// Кавычка в значении строкового параметра дала бы key = "va"lue" — движок
// после такого не поднимется.
func TestExpertValueRejectsQuotesAndBrackets(t *testing.T) {
	for _, v := range []string{`["127.0.0.1/32"]`, `va"lue`, "[]"} {
		if err := ValidateExpertParam("censorship", "tls_domain", v); err == nil {
			t.Errorf("значение %q должно отвергаться", v)
		}
	}
}

// Символы, которые сломали бы формат "section|key|value" в expert.conf или
// подставились бы как флаг, остаются под запретом.
func TestExpertValueStillRejectsDangerous(t *testing.T) {
	bad := map[string]string{
		"перевод строки":     "127.0.0.1\n[evil]",
		"вертикальная черта": "a|b",
		"ведущий дефис":      "-rf",
		"возврат каретки":    "a\rb",
		"обратный слеш":      `C:\evil`,
		"доллар":             "$(whoami)",
		"обратные кавычки":   "`id`",
		"точка с запятой":    "a;b",
	}
	for name, v := range bad {
		if err := ValidateExpertParam("server.api", "whitelist", v); err == nil {
			t.Errorf("%s: значение %q должно отвергаться", name, v)
		}
	}
}
