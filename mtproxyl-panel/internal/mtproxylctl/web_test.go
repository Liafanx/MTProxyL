package mtproxylctl

import "testing"

func TestValidateWebParamAllowsSiteSource(t *testing.T) {
	for _, value := range []string{
		"mekorunner",
		"https://example.com/index.html",
		"/var/www/example.com",
	} {
		if err := ValidateWebParam("WEB_DECOY_SOURCE", value); err != nil {
			t.Errorf("ValidateWebParam site source %q: %v", value, err)
		}
	}
}

func TestValidateWebParamRejectsSelfmaskKey(t *testing.T) {
	if err := ValidateWebParam("SELFMASK_DOMAIN", "example.com"); err == nil {
		t.Fatal("ValidateWebParam accepted an unrelated Selfmask key")
	}
}
