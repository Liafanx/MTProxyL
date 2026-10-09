package mtproxylctl

import (
	"context"
	"strings"
	"testing"
)

func TestValidateSecretLabel(t *testing.T) {
	ok := []string{"alice", "user1", "a", "A_b-c", "7bob", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	for _, l := range ok {
		if err := ValidateSecretLabel(l); err != nil {
			t.Errorf("метка %q должна приниматься: %s", l, err)
		}
	}
	bad := []string{"", "--help", "-x", "_leading", "../etc", "a b", "имя", "a/b", "a;id",
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	for _, l := range bad {
		if err := ValidateSecretLabel(l); err == nil {
			t.Errorf("метка %q должна отвергаться", l)
		}
	}
}

// Export goes to the browser verbatim; import pipes the file through stdin.
func TestSecretsExportImport(t *testing.T) {
	c := newStubClient(t)
	body, err := c.ExportSecrets(context.Background())
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	if !strings.Contains(body, "alice|0123456789abcdef0123456789abcdef|true|5|0|1073741824|0||") {
		t.Errorf("unexpected export %q", body)
	}
	out, err := c.ImportSecrets(context.Background(), body)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if !strings.Contains(out, "Импортировано: 1") || strings.Contains(out, "\x1b") {
		t.Errorf("unexpected import output %q", out)
	}
}

// The header travels through stdin; quotes and pipes are refused before the CLI.
func TestAPIAuth(t *testing.T) {
	c := newStubClient(t)
	set, err := c.APIAuthSet(context.Background())
	if err != nil || !set {
		t.Fatalf("APIAuthSet = %v, %v", set, err)
	}
	out, err := c.SetAPIAuth(context.Background(), "Bearer abc")
	if err != nil || !strings.Contains(out, "got:Bearer abc") {
		t.Fatalf("set: %q, %v", out, err)
	}
	if out, err = c.SetAPIAuth(context.Background(), ""); err != nil || !strings.Contains(out, "cleared") {
		t.Fatalf("clear: %q, %v", out, err)
	}
	for _, bad := range []string{`a"b`, "a|b", "a\nb", `a\b`} {
		if _, err := c.SetAPIAuth(context.Background(), bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}
