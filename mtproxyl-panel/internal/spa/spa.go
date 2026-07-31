package spa

import (
	"io/fs"
	"net/http"
	"strings"
)

func NewHandler(distFS fs.FS, basePath string) http.Handler {
	fsys, _ := fs.Sub(distFS, "dist")
	fileServer := http.FileServer(http.FS(fsys))

	// Read and patch index.html once at startup
	indexHTML, _ := fs.ReadFile(fsys, "index.html")
	var patchedIndex []byte
	if len(indexHTML) > 0 {
		baseHref := basePath + "/"
		if basePath == "" {
			baseHref = "/"
		}
		injection := `<base href="` + baseHref + `">` +
			`<script>window.__BASE_PATH__="` + basePath + `"</script>`
		patchedIndex = []byte(strings.Replace(string(indexHTML), "<head>", "<head>"+injection, 1))
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/")
		if path == "" {
			path = "index.html"
		}

		f, err := fsys.Open(path)
		if err != nil {
			// SPA fallback: serve patched index.html for client-side routing
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
			w.Write(patchedIndex)
			return
		}
		f.Close()

		if path == "index.html" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
			w.Write(patchedIndex)
			return
		}

		// Long cache for hashed assets
		if strings.HasPrefix(path, "assets/") {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}

		fileServer.ServeHTTP(w, r)
	})
}
