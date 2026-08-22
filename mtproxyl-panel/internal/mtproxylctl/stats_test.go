package mtproxylctl

import "testing"

func TestStatsScopes(t *testing.T) {
	for _, s := range []string{"all", "traffic", "ips", "orphans", "user"} {
		if !statsScopes[s] {
			t.Errorf("область %q должна быть разрешена", s)
		}
	}
	for _, s := range []string{"", "everything", "reset", "user; ls"} {
		if statsScopes[s] {
			t.Errorf("область %q не должна быть разрешена", s)
		}
	}
}
