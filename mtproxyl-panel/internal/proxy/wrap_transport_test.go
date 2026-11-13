package proxy

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type recordRT struct{ paths []string }

func (r *recordRT) RoundTrip(req *http.Request) (*http.Response, error) {
	r.paths = append(r.paths, req.Method+" "+req.URL.Path)
	body := `{"ok":true,"data":{"version":"shim"}}`
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}},
		Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: req}, nil
}

// Цель mtdd: и обратный прокси /api/telemt/*, и GetJSON (recorder истории)
// должны идти через перехватчик, а не в сеть.
func TestWrapTransportCoversProxyAndJSONClient(t *testing.T) {
	tp, err := NewTelemtProxy("http://127.0.0.1:1", "")
	if err != nil {
		t.Fatal(err)
	}
	rec := &recordRT{}
	tp.WrapTransport(func(http.RoundTripper) http.RoundTripper { return rec })

	w := httptest.NewRecorder()
	tp.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/telemt/v1/users", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "shim") {
		t.Fatalf("reverse proxy bypassed the wrapper: %d %s", w.Code, w.Body.String())
	}
	var out struct {
		Version string `json:"version"`
	}
	if err := tp.GetJSON(context.Background(), "/v1/system/info", &out); err != nil || out.Version != "shim" {
		t.Fatalf("GetJSON bypassed the wrapper: %v %+v", err, out)
	}
	if len(rec.paths) != 2 || rec.paths[0] != "GET /v1/users" || rec.paths[1] != "GET /v1/system/info" {
		t.Fatalf("paths: %v", rec.paths)
	}
}
