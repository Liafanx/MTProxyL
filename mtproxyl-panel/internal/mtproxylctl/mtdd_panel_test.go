package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

// Команды для mtdd уходят в CLI ровно теми аргументами, на которые выписаны
// права sudo в install.sh, а вход вне пределов до CLI не доходит.
func TestMtddPanelCommands(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	body := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"  'suspects status --json') echo '{\"available\":true,\"suspects\":[]}' ;;\n" +
		"  'upstream overlay --json') echo '[{\"kind\":\"awg\",\"enabled\":true,\"title\":\"AWG\",\"detail\":\"\"}]' ;;\n" +
		"  *) echo \"ARGS:$*\" ;;\n" +
		"esac\n"
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
	ctx := context.Background()

	doc, err := c.GetMtddSuspects(ctx)
	if err != nil || !strings.Contains(string(doc), `"available":true`) {
		t.Fatalf("suspects status: %s %v", doc, err)
	}
	ov, err := c.UpstreamOverlayList(ctx)
	if err != nil || len(ov) != 1 || ov[0].Kind != "awg" || !ov[0].Enabled {
		t.Fatalf("overlay: %+v %v", ov, err)
	}
	for _, tc := range []struct {
		run  func() (string, error)
		want string
	}{
		{func() (string, error) { return c.SetSecretDevices(ctx, "alice", 3) }, "ARGS:secret setdevices alice 3"},
		{func() (string, error) { return c.SetSecretDevices(ctx, "alice", 0) }, "ARGS:secret setdevices alice 0"},
		{func() (string, error) { return c.SetMtddSuspectsEnabled(ctx, true) }, "ARGS:suspects on"},
		{func() (string, error) { return c.SetMtddSuspectsEnabled(ctx, false) }, "ARGS:suspects off"},
		{func() (string, error) { return c.SetMtddSuspectsBan(ctx, 0) }, "ARGS:suspects ban 0"},
		{func() (string, error) { return c.MtddSuspectsBlock(ctx, 60) }, "ARGS:suspects block 60"},
		{func() (string, error) { return c.MtddSuspectsUnblock(ctx) }, "ARGS:suspects unblock"},
	} {
		out, err := tc.run()
		if err != nil || strings.TrimSpace(out) != tc.want {
			t.Errorf("got %q %v, want %q", out, err, tc.want)
		}
	}
	for name, run := range map[string]func() (string, error){
		"devices -1":      func() (string, error) { return c.SetSecretDevices(ctx, "alice", -1) },
		"devices 1000001": func() (string, error) { return c.SetSecretDevices(ctx, "alice", 1_000_001) },
		"devices label":   func() (string, error) { return c.SetSecretDevices(ctx, "a b", 1) },
		"ban 101":         func() (string, error) { return c.SetMtddSuspectsBan(ctx, 101) },
		"block 0":         func() (string, error) { return c.MtddSuspectsBlock(ctx, 0) },
	} {
		if _, err := run(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
