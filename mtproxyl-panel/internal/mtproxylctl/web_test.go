package mtproxylctl

import (
	"strings"
	"testing"
)

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

func TestWebHAProxyStatusAndConfig(t *testing.T) {
	c := newStubClient(t)
	status, err := c.WebStatus(t.Context())
	if err != nil {
		t.Fatalf("WebStatus: %v", err)
	}
	if status.Frontend != "haproxy" || !status.HAProxyReady || status.ProxyPort != 443 {
		t.Fatalf("unexpected WEB status: %+v", status)
	}
	config, err := c.WebHAProxyConfig(t.Context())
	if err != nil {
		t.Fatalf("WebHAProxyConfig: %v", err)
	}
	if !strings.Contains(config, "frontend mtproxyl_public\n    bind :443") {
		t.Fatalf("unexpected HAProxy config: %q", config)
	}
}
