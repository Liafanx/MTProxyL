package mtproxylctl

import "testing"

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
