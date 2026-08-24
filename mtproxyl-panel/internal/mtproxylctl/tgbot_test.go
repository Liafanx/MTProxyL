package mtproxylctl

import (
	"encoding/json"
	"testing"
)

// The bot's SOCKS5 route used to be dropped here: the struct had no field for
// it, so the panel always rendered an empty input over the placeholder.
func TestTgbotStatusKeepsProxy(t *testing.T) {
	const raw = `{"installed":true,"configured":true,"active":true,"enabled":true,
		"dir":"/opt/mtproxyl-tgbot","service":"mtproxyl-tgbot.service",
		"config":{"admins":[1],"notify":{"proxy":true},"intervals":{"proxy":5},
		"autobackup":{"enabled":false,"time":"05:30","send_file":true},
		"proxy":"socks5://user:secret@10.0.0.9:1080","has_token":true}}`

	var st TgbotStatus
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		t.Fatalf("Unmarshal() = %v, want nil", err)
	}
	if want := "socks5://user:secret@10.0.0.9:1080"; st.Config.Proxy != want {
		t.Errorf("Config.Proxy = %q, want %q", st.Config.Proxy, want)
	}
	if !st.Config.HasToken {
		t.Error("Config.HasToken = false, want true")
	}

	// The panel re-marshals the struct for the browser: the key has to survive
	// that leg too, otherwise the form still comes back empty.
	out, err := json.Marshal(st)
	if err != nil {
		t.Fatalf("Marshal() = %v, want nil", err)
	}
	var back TgbotStatus
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatalf("Unmarshal(round trip) = %v, want nil", err)
	}
	if back.Config.Proxy != st.Config.Proxy {
		t.Errorf("round trip Config.Proxy = %q, want %q", back.Config.Proxy, st.Config.Proxy)
	}
}

// Direct connection is an empty string, not a missing key: the input has to be
// clearable from the panel.
func TestTgbotStatusEmptyProxy(t *testing.T) {
	const raw = `{"installed":true,"config":{"proxy":"","has_token":false}}`
	var st TgbotStatus
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		t.Fatalf("Unmarshal() = %v, want nil", err)
	}
	if st.Config.Proxy != "" {
		t.Errorf("Config.Proxy = %q, want empty", st.Config.Proxy)
	}
}
