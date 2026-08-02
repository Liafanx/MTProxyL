package mtproxylctl

import (
	"context"
	"errors"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestValidateBackupNameRejectsTraversal(t *testing.T) {
	// These names must never reach a sudo-invoked restore.
	bad := []string{
		"",
		"../../etc/shadow",
		"/etc/shadow",
		"mtproxyl-20260101-101010.tar.gz/../../evil",
		"..",
		".",
		"mtproxyl-20260101-101010.tar.gz ; rm -rf /",
		"mtproxyl-20260101-101010.tar.gz\nrm -rf /",
		"--encrypted",
		"-rf",
		"mtproxyl-2026011-101010.tar.gz", // too few date digits
		"mtproxyl-20260101-10101.tar.gz", // too few time digits
		"mtproxyl-20260101-101010.tar",   // wrong extension
		"mtproxyl-20260101-101010.tar.gz2",
		"MTPROXYL-20260101-101010.tar.gz", // wrong case
		"pre-migrate-1234567890.tar.gz",
		"subdir/mtproxyl-20260101-101010.tar.gz",
	}
	for _, name := range bad {
		if err := ValidateBackupName(name); err == nil {
			t.Errorf("ValidateBackupName(%q) = nil, want error", name)
		}
	}
}

func TestValidateBackupNameAcceptsRealNames(t *testing.T) {
	good := []string{
		"mtproxyl-20260101-101010.tar.gz",
		"mtproxyl-19991231-235959.tar.gz",
	}
	for _, name := range good {
		if err := ValidateBackupName(name); err != nil {
			t.Errorf("ValidateBackupName(%q) = %v, want nil", name, err)
		}
	}
}

func TestResolveBackupPath(t *testing.T) {
	c := New(config.MtproxylConfig{Enabled: true, InstallDir: "/opt/mtproxyl"})

	got, err := c.ResolveBackupPath("mtproxyl-20260101-101010.tar.gz")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := "/opt/mtproxyl/backups/mtproxyl-20260101-101010.tar.gz"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	if _, err := c.ResolveBackupPath("../../etc/shadow"); err == nil {
		t.Error("traversal name accepted, want error")
	}
}

func TestStripANSI(t *testing.T) {
	cases := map[string]string{
		"\x1b[32m[✓]\x1b[0m готово": "[✓] готово",
		"plain":                     "plain",
		"\x1b[1;31merror\x1b[0m":    "error",
		"":                          "",
	}
	for in, want := range cases {
		if got := stripANSI(in); got != want {
			t.Errorf("stripANSI(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFirstJSONLine(t *testing.T) {
	// MTProxyL may print a stray line before the payload.
	out := "  [i] загрузка\n{\"mode\":\"manager\"}\n"
	if got, want := firstJSONLine(out), `{"mode":"manager"}`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	arr := "[{\"name\":\"a\"}]"
	if got := firstJSONLine(arr); got != arr {
		t.Errorf("got %q, want %q", got, arr)
	}
}

func TestLastMeaningfulLinePrefersFirstStream(t *testing.T) {
	got := lastMeaningfulLine("\x1b[31mfatal: boom\x1b[0m\n\n", "stdout line")
	if want := "fatal: boom"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	// Falls back to the next stream when the first is empty.
	if got := lastMeaningfulLine("   \n", "from stdout"); got != "from stdout" {
		t.Errorf("got %q, want %q", got, "from stdout")
	}
}

func TestDisabledClientRefusesToRun(t *testing.T) {
	c := New(config.MtproxylConfig{Enabled: false})
	if _, err := c.GetMode(context.Background()); !errors.Is(err, ErrDisabled) {
		t.Errorf("got %v, want ErrDisabled", err)
	}
}

func TestSwitchModeRejectsUnknownMode(t *testing.T) {
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: "/nonexistent"})
	if err := c.SwitchMode(context.Background(), Mode("root"), ContainerRemove); err == nil {
		t.Error("expected error for unknown mode")
	}
}

// Going to reanimator without saying what to do with the container must fail
// rather than fall through to the CLI, whose default deletes it.
func TestSwitchToReanimatorRequiresDisposition(t *testing.T) {
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: "/nonexistent"})
	if err := c.SwitchMode(context.Background(), ModeReanimator, ""); err == nil {
		t.Error("expected error when the container disposition is missing")
	}
	if err := c.SwitchMode(context.Background(), ModeReanimator, "delete"); err == nil {
		t.Error("expected error for an unknown container disposition")
	}
}

func TestProxyActionValid(t *testing.T) {
	for _, a := range []ProxyAction{ProxyStart, ProxyStop, ProxyRestart} {
		if !a.Valid() {
			t.Errorf("%q rejected", a)
		}
	}
	for _, a := range []ProxyAction{"", "reload", "start; id", "../start"} {
		if ProxyAction(a).Valid() {
			t.Errorf("%q accepted", a)
		}
	}
}

func TestTimeoutFallback(t *testing.T) {
	if got := (config.MtproxylConfig{}).Timeout(); got.Minutes() != 10 {
		t.Errorf("default timeout = %v, want 10m", got)
	}
	if got := (config.MtproxylConfig{CommandTimeout: "bogus"}).Timeout(); got.Minutes() != 10 {
		t.Errorf("invalid timeout = %v, want 10m fallback", got)
	}
	if got := (config.MtproxylConfig{CommandTimeout: "30s"}).Timeout(); got.Seconds() != 30 {
		t.Errorf("timeout = %v, want 30s", got)
	}
}
