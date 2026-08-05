package proxy

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGetManagedConfig(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/config" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
			return
		}
		if r.Header.Get("Authorization") != "Bearer tok" {
			t.Errorf("missing auth header")
			return
		}
		w.Write([]byte(`{"ok":true,"data":{"general":{"use_middle_proxy":true}},"revision":"rev1"}`))
	}))
	defer srv.Close()

	p, _ := NewTelemtProxy(srv.URL, "Bearer tok")
	sections, rev, err := p.GetManagedConfig()
	if err != nil {
		t.Fatalf("GetManagedConfig: %v", err)
	}
	if rev != "rev1" {
		t.Fatalf("revision = %q, want rev1", rev)
	}
	if g, ok := sections["general"].(map[string]interface{}); !ok || g["use_middle_proxy"] != true {
		t.Fatalf("sections = %#v", sections)
	}
}

func TestGetManagedConfigPreservesIntegers(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true,"data":{"server":{"port":443}},"revision":"r"}`))
	}))
	defer srv.Close()

	p, _ := NewTelemtProxy(srv.URL, "Bearer tok")
	sections, _, err := p.GetManagedConfig()
	if err != nil {
		t.Fatalf("GetManagedConfig: %v", err)
	}
	server, ok := sections["server"].(map[string]interface{})
	if !ok {
		t.Fatalf("server section = %#v", sections["server"])
	}
	if _, ok := server["port"].(json.Number); !ok {
		t.Fatalf("port type = %T, want json.Number (UseNumber must be enabled)", server["port"])
	}
}

func TestPatchManagedConfigSendsIfMatch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch || r.URL.Path != "/v1/config" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
			return
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("Content-Type = %q, want application/json", r.Header.Get("Content-Type"))
			return
		}
		if r.Header.Get("If-Match") != "rev1" {
			t.Errorf("If-Match = %q, want rev1", r.Header.Get("If-Match"))
			return
		}
		body, _ := io.ReadAll(r.Body)
		var patch map[string]interface{}
		json.Unmarshal(body, &patch)
		if _, ok := patch["general"]; !ok {
			t.Errorf("patch missing general: %s", body)
			return
		}
		w.Write([]byte(`{"ok":true,"data":{"revision":"rev2","restart_required":true,"changed":["general"]},"revision":"rev2"}`))
	}))
	defer srv.Close()

	p, _ := NewTelemtProxy(srv.URL, "Bearer tok")
	res, err := p.PatchManagedConfig(map[string]interface{}{"general": map[string]interface{}{"ad_tag": "x"}}, "rev1")
	if err != nil {
		t.Fatalf("PatchManagedConfig: %v", err)
	}
	if res.Revision != "rev2" || !res.RestartRequired {
		t.Fatalf("res = %#v", res)
	}
}

func TestPatchManagedConfigConflict(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		w.Write([]byte(`{"ok":false,"error":{"code":"revision_conflict","message":"Config revision mismatch"},"request_id":1}`))
	}))
	defer srv.Close()

	p, _ := NewTelemtProxy(srv.URL, "Bearer tok")
	_, err := p.PatchManagedConfig(map[string]interface{}{"general": map[string]interface{}{}}, "stale")
	if err == nil || !strings.Contains(err.Error(), "revision_conflict") {
		t.Fatalf("expected revision_conflict error, got %v", err)
	}
	var apiErr *TelemtAPIError
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusConflict {
		t.Fatalf("expected TelemtAPIError 409, got %v", err)
	}
}
