package mtproxylctl

import "testing"

func TestIsMtddBothModes(t *testing.T) {
	cases := []struct {
		st   *ModeStatus
		want bool
	}{
		{nil, false},
		{&ModeStatus{Mode: ModeReanimator, EngineKind: "mtdd"}, true},
		{&ModeStatus{Mode: ModeManager, EngineKind: "mtdd"}, true},
		{&ModeStatus{Mode: ModeManager, EngineKind: "telemt"}, false},
		{&ModeStatus{Mode: ModeReanimator, EngineKind: ""}, false},
	}
	for _, c := range cases {
		if got := c.st.IsMtdd(); got != c.want {
			t.Errorf("IsMtdd(%+v) = %v, want %v", c.st, got, c.want)
		}
	}
}
