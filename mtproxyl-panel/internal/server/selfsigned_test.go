package server

import (
	"crypto/tls"
	"crypto/x509"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestEnsureSelfSignedCert(t *testing.T) {
	dir := t.TempDir()
	certFile := filepath.Join(dir, "certs", "panel.crt")
	keyFile := filepath.Join(dir, "certs", "panel.key")

	if err := ensureSelfSignedCert(certFile, keyFile, []string{"panel.example.com", "203.0.113.10"}); err != nil {
		t.Fatalf("генерация не удалась: %s", err)
	}

	// Пара должна грузиться как настоящая TLS-пара.
	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		t.Fatalf("пара не грузится: %s", err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatalf("сертификат не разбирается: %s", err)
	}

	// Имена и адреса должны попасть в сертификат, иначе браузер ругается ещё и
	// на несовпадение имени, а не только на недоверенность.
	if err := leaf.VerifyHostname("panel.example.com"); err != nil {
		t.Errorf("домен не в сертификате: %s", err)
	}
	if err := leaf.VerifyHostname("localhost"); err != nil {
		t.Errorf("localhost не в сертификате: %s", err)
	}
	hasIP := func(want string) bool {
		for _, ip := range leaf.IPAddresses {
			if ip.Equal(net.ParseIP(want)) {
				return true
			}
		}
		return false
	}
	for _, want := range []string{"203.0.113.10", "127.0.0.1", "::1"} {
		if !hasIP(want) {
			t.Errorf("адрес %s не в сертификате", want)
		}
	}
	if leaf.NotAfter.Before(time.Now().Add(365 * 24 * time.Hour)) {
		t.Errorf("сертификат живёт меньше года: до %s", leaf.NotAfter)
	}

	// Ключ не должен быть доступен на чтение никому, кроме владельца.
	st, err := os.Stat(keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Errorf("права на ключ %o, ожидалось 600", perm)
	}

	// Повторный вызов не должен перегенерировать: иначе перезапуск панели
	// каждый раз давал бы новый сертификат и новое предупреждение браузера.
	before, _ := os.ReadFile(certFile)
	if err := ensureSelfSignedCert(certFile, keyFile, nil); err != nil {
		t.Fatalf("повторный вызов упал: %s", err)
	}
	after, _ := os.ReadFile(certFile)
	if string(before) != string(after) {
		t.Error("сертификат перегенерирован, хотя уже был на месте")
	}
}

// Половина пары — это сервер, который стартует и роняет каждое рукопожатие.
func TestEnsureSelfSignedRefusesHalfPair(t *testing.T) {
	dir := t.TempDir()
	certFile := filepath.Join(dir, "panel.crt")
	keyFile := filepath.Join(dir, "panel.key")
	if err := os.WriteFile(certFile, []byte("чужой сертификат"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := ensureSelfSignedCert(certFile, keyFile, nil)
	if err == nil {
		t.Fatal("ожидалась ошибка при непарном сертификате")
	}
	t.Logf("отказ: %s", err)
}

func TestEnsureSelfSignedNeedsBothPaths(t *testing.T) {
	if err := ensureSelfSignedCert("", "", nil); err == nil {
		t.Fatal("пустые пути должны отвергаться")
	}
}
