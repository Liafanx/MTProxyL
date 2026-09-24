package mtproxylctl

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

func TestWarpEndpointValidation(t *testing.T) {
	for _, ep := range []string{"188.114.98.58:2408", "[2606:4700:d0::a29f:c001]:2408"} {
		if !validWarpEndpoint(ep) {
			t.Errorf("rejected %q", ep)
		}
	}
	for _, ep := range []string{"127.0.0.1:0", "127.0.0.1:65536", "999.1.1.1:443", "[:::1]:443", "[::1%eth0]:443", "localhost:443", "1.2.3.4:443;id"} {
		if validWarpEndpoint(ep) {
			t.Errorf("accepted %q", ep)
		}
	}
}

func TestWarpSettingsOneInvocation(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
	proto, loc, ep := "masque-h2", "de,ams", "[2606:4700::1]:443"
	out, err := c.WarpSetSettings(context.Background(), &proto, &loc, &ep)
	if err != nil {
		t.Fatal(err)
	}
	if out != "warp\nsettings\nmasque-h2\nDE,AMS\n[2606:4700::1]:443\n" {
		t.Fatalf("args: %q", out)
	}
	loc = "DE;id"
	if _, err := c.WarpSetSettings(context.Background(), &proto, &loc, &ep); err == nil {
		t.Fatal("invalid settings accepted")
	}
	out, err = c.WarpSetSettings(context.Background(), nil, nil, nil)
	if err != nil || !strings.Contains(out, "settings\nkeep\nkeep\nkeep\n") {
		t.Fatalf("partial patch: %q %v", out, err)
	}
}

func TestWarpPreflightAndEnableConsent(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	body := `#!/bin/sh
if [ "$*" = 'warp preflight upstream --json' ]; then
  echo '{"mode":"upstream","middle_proxy_enabled":true,"can_disable_middle_proxy":true,"owns_engine_config":true,"manual_engine_config":false,"default_upstreams":["direct"],"can_disable_default_upstreams":true}'
  exit 0
fi
printf '%s\n' "$@"
`
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
	p, err := c.WarpPreflight(context.Background(), "upstream")
	if err != nil {
		t.Fatal(err)
	}
	if !p.MiddleProxyEnabled || !p.CanDisableMiddleProxy || len(p.DefaultUpstreams) != 1 || p.DefaultUpstreams[0] != "direct" {
		t.Fatalf("preflight: %+v", p)
	}
	out, err := c.WarpEnable(context.Background(), "upstream", true, true)
	if err != nil {
		t.Fatal(err)
	}
	want := "warp\non\nupstream\n--allow-disable-me\n--allow-disable-default-upstreams\n"
	if out != want {
		t.Fatalf("enable args: %q", out)
	}
	if _, err := c.WarpPreflight(context.Background(), "unknown"); err == nil {
		t.Fatal("invalid mode accepted")
	}
}

func TestWarpScanExtendedAndLegacyReports(t *testing.T) {
	for _, report := range []string{
		`{"scanned_at":1,"status":"success","best_endpoint":"1.2.3.4:443","nodes":[{"node":"FRA","endpoint":"1.2.3.4:443","tunnel_ping":"12ms","loss":"0%"}]}`,
		`{"scanned_at":0,"nodes":[]}`,
		`{"scanned_at":1,"status":"error","error":"scan failed","nodes":[]}`,
	} {
		dir := t.TempDir()
		script := filepath.Join(dir, "cli")
		if err := os.WriteFile(script, []byte("#!/bin/sh\n[ \"$*\" = 'warp scan --json' ] || exit 1\nprintf '%s\\n' '"+report+"'\n"), 0700); err != nil {
			t.Fatal(err)
		}
		c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
		res, err := c.WarpGetScan(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if res.Status == "success" && (res.BestEndpoint == "" || res.Nodes[0].Loss != "0%") {
			t.Fatalf("lost fields: %+v", res)
		}
	}
}

func TestWarpScanDepth(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "cli")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script})
	for _, tc := range []struct {
		mode string
		deep bool
		want string
	}{
		{"", false, "warp\nscan\n"},
		{"", true, "warp\nscan\n--deep\n"},
		{"iface", true, "warp\nscan\niface\n--deep\n"},
	} {
		got, err := c.WarpScanMode(context.Background(), tc.mode, tc.deep)
		if err != nil || got != tc.want {
			t.Fatalf("scan(%q,%v): %q, %v", tc.mode, tc.deep, got, err)
		}
	}
	if _, err := c.WarpScanMode(context.Background(), "other", true); err == nil {
		t.Fatal("invalid mode accepted")
	}
}
