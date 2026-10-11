// mtproxyl-static — раздача сайта-заглушки за HAProxy.
// HAProxy файлы не отдаёт, поэтому он держит TLS, а сайт берёт отсюда.
// Слушает только loopback; заголовки безопасности добавляет HAProxy.
package main

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

var version = "dev"

// Без mime.types в системе CSS отдался бы как text/plain, а с nosniff
// браузер такой стиль не применяет.
var builtinTypes = map[string]string{
	".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8",
	".css": "text/css; charset=utf-8", ".js": "application/javascript",
	".json": "application/json", ".txt": "text/plain; charset=utf-8",
	".xml": "application/xml", ".avif": "image/avif", ".gif": "image/gif",
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
	".svg": "image/svg+xml", ".webp": "image/webp", ".ico": "image/x-icon",
	".woff": "font/woff", ".woff2": "font/woff2", ".pdf": "application/pdf",
	".wasm": "application/wasm", ".webmanifest": "application/manifest+json",
}

type site struct {
	root     string
	notFound string
	indexes  []string
}

func (s *site) open(rel string) (*os.File, fs.FileInfo, error) {
	full := filepath.Join(s.root, filepath.FromSlash(rel))
	if full != s.root && !strings.HasPrefix(full, s.root+string(filepath.Separator)) {
		return nil, nil, fs.ErrNotExist
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, nil, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	return f, st, nil
}

func (s *site) serveFile(w http.ResponseWriter, r *http.Request, f *os.File, st fs.FileInfo, code int) {
	defer f.Close()
	if ct := builtinTypes[strings.ToLower(path.Ext(st.Name()))]; ct != "" {
		w.Header().Set("Content-Type", ct)
	} else if ct := mime.TypeByExtension(path.Ext(st.Name())); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	if code != http.StatusOK {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(code)
		if r.Method != http.MethodHead {
			_, _ = io.Copy(w, f)
		}
		return
	}
	// ETag в духе nginx: время изменения и размер.
	w.Header().Set("ETag", fmt.Sprintf("\"%x-%x\"", st.ModTime().Unix(), st.Size()))
	http.ServeContent(w, r, st.Name(), st.ModTime(), f)
}

func (s *site) notFoundPage(w http.ResponseWriter, r *http.Request) {
	if f, st, err := s.open(s.notFound); err == nil && st.Mode().IsRegular() {
		s.serveFile(w, r, f, st, http.StatusNotFound)
		return
	}
	http.Error(w, "404 Not Found", http.StatusNotFound)
}

func (s *site) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "405 Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	rel := path.Clean("/" + r.URL.Path)
	f, st, err := s.open(rel)
	if err != nil {
		s.notFoundPage(w, r)
		return
	}
	if st.IsDir() {
		f.Close()
		// Как у nginx: каталог без слеша — редирект, относительный, чтобы
		// не выдать внутренний порт.
		if !strings.HasSuffix(r.URL.Path, "/") {
			target := path.Base(rel) + "/"
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			w.Header().Set("Location", target)
			w.WriteHeader(http.StatusMovedPermanently)
			return
		}
		for _, idx := range s.indexes {
			if f2, st2, err2 := s.open(path.Join(rel, idx)); err2 == nil {
				if st2.Mode().IsRegular() {
					s.serveFile(w, r, f2, st2, http.StatusOK)
					return
				}
				f2.Close()
			}
		}
		s.notFoundPage(w, r)
		return
	}
	if !st.Mode().IsRegular() {
		f.Close()
		s.notFoundPage(w, r)
		return
	}
	s.serveFile(w, r, f, st, http.StatusOK)
}

func main() {
	listen := flag.String("listen", "127.0.0.1:15481", "адрес")
	root := flag.String("root", "/var/www/mtproxyl-selfmask", "каталог сайта")
	notFound := flag.String("404", "/404.html", "страница 404 внутри сайта")
	showVersion := flag.Bool("version", false, "версия")
	flag.Parse()
	if *showVersion {
		println(version)
		return
	}
	abs, err := filepath.Abs(*root)
	if err != nil {
		log.Fatal(err)
	}
	s := &site{root: filepath.Clean(abs), notFound: *notFound, indexes: []string{"index.html", "index.htm"}}
	srv := &http.Server{
		Addr:              *listen,
		Handler:           s,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
