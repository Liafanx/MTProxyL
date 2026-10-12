// mtproxyl-api — внешний HTTP API MTProxyL: пользователи, их лимиты и
// состояние прокси. Работает без панели; ставится командой `mtproxyl api on`.
package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/extapi"
	"github.com/Liafanx/mtproxyl-panel/internal/mtproxylctl"
)

var version = "dev"

func main() {
	listen := flag.String("listen", "127.0.0.1:9190", "адрес и порт")
	keyFile := flag.String("key-file", "/etc/mtproxyl-api/key.sha256", "SHA-256 ключа в hex")
	script := flag.String("script", "/opt/mtproxyl/mtproxyl.sh", "путь к mtproxyl.sh")
	installDir := flag.String("install-dir", "/opt/mtproxyl", "каталог MTProxyL")
	useSudo := flag.Bool("sudo", true, "звать mtproxyl через sudo")
	timeout := flag.String("timeout", "5m", "предел одной команды")
	allow := flag.String("allow", "", "разрешённые адреса через запятую (CIDR или IP)")
	tlsCert := flag.String("tls-cert", "", "сертификат для HTTPS")
	tlsKey := flag.String("tls-key", "", "ключ для HTTPS")
	showVersion := flag.Bool("version", false, "версия")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	raw, err := os.ReadFile(*keyFile)
	if err != nil {
		log.Fatalf("ключ API: %v (создайте: mtproxyl api key)", err)
	}
	var hash [32]byte
	b, err := hex.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(b) != 32 {
		log.Fatalf("ключ API: в %s ожидается SHA-256 в hex", *keyFile)
	}
	copy(hash[:], b)

	nets, err := parseAllow(*allow)
	if err != nil {
		log.Fatalf("allow: %v", err)
	}

	cli := mtproxylctl.New(config.MtproxylConfig{
		Enabled: true, ScriptPath: *script, InstallDir: *installDir,
		UseSudo: *useSudo, CommandTimeout: *timeout,
	})
	srv := &http.Server{
		Addr:              *listen,
		Handler:           extapi.LogRequests(extapi.New(cli, hash, nets, version)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      6 * time.Minute,
		IdleTimeout:       2 * time.Minute,
	}
	log.Printf("mtproxyl-api %s слушает %s (%s)", version, *listen, map[bool]string{true: "https", false: "http"}[*tlsCert != ""])
	if *tlsCert != "" {
		log.Fatal(srv.ListenAndServeTLS(*tlsCert, *tlsKey))
	}
	log.Fatal(srv.ListenAndServe())
}

func parseAllow(s string) ([]*net.IPNet, error) {
	var out []*net.IPNet
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if !strings.Contains(part, "/") {
			if ip := net.ParseIP(part); ip != nil {
				if ip.To4() != nil {
					part += "/32"
				} else {
					part += "/128"
				}
			}
		}
		_, n, err := net.ParseCIDR(part)
		if err != nil {
			return nil, fmt.Errorf("%q: не CIDR и не IP", part)
		}
		out = append(out, n)
	}
	return out, nil
}
