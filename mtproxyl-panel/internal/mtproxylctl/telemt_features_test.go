package mtproxylctl

import "testing"

func TestTelemtFeatureParams(t *testing.T) {
	for _, v := range []string{`{}`, `{"alice":"monthly","bob":"weekly"}`} {
		if err := ValidateExpertParam("access", "user_quota_periods", v); err != nil {
			t.Fatal(err)
		}
	}
	for _, v := range []string{`null`, `[]`, `{"alice":"yearly"}`, `{"alice":1}`, `{"a\"":"daily"}`} {
		if err := ValidateExpertParam("access", "user_quota_periods", v); err == nil {
			t.Fatalf("accepted %s", v)
		}
	}
	if err := ValidateExpertParam("general", "log_level", `{"alice":"monthly"}`); err == nil {
		t.Fatal("JSON accepted for a scalar")
	}
	if err := ValidateWebParam("WEB_HOSTS", "alt.example.org,*.example.org"); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{"a.org;id", "a.org\nb.org", `a.org"`, "$(id)"} {
		if err := ValidateWebParam("WEB_HOSTS", v); err == nil {
			t.Fatalf("accepted %q", v)
		}
	}
}
