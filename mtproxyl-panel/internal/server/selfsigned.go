package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// selfSignedValidity is deliberately long: this certificate is pinned by the
// operator clicking through a browser warning once, and a yearly expiry would
// only mean re-clicking with no security gained.
const selfSignedValidity = 10 * 365 * 24 * time.Hour

// ensureSelfSignedCert writes a certificate and key to the given paths if they
// are not already there, and reports whether TLS can be served from them.
// A self-signed certificate still warns in the browser, but it encrypts the
// admin password and session token — which is the part that matters.
func ensureSelfSignedCert(certFile, keyFile string, hosts []string) error {
	if certFile == "" || keyFile == "" {
		return fmt.Errorf("cert_file and key_file must both be set for self-signed TLS")
	}
	if fileExists(certFile) && fileExists(keyFile) {
		return nil
	}
	// Refuse to pair a fresh key with someone else's certificate: that yields a
	// server that starts and then fails every handshake.
	if fileExists(certFile) != fileExists(keyFile) {
		return fmt.Errorf("only one of %s / %s exists — remove it or provide both",
			certFile, keyFile)
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate key: %w", err)
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("generate serial: %w", err)
	}

	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "MTProxyL-Panel"},
		NotBefore:             time.Now().Add(-time.Hour), // терпим расхождение часов
		NotAfter:              time.Now().Add(selfSignedValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	for _, h := range hosts {
		if h == "" {
			continue
		}
		if ip := net.ParseIP(h); ip != nil {
			tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
		} else {
			tmpl.DNSNames = append(tmpl.DNSNames, h)
		}
	}
	// Локальный доступ должен работать всегда — по нему ходит и сам сервер.
	tmpl.IPAddresses = append(tmpl.IPAddresses, net.ParseIP("127.0.0.1"), net.ParseIP("::1"))
	tmpl.DNSNames = append(tmpl.DNSNames, "localhost")

	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return fmt.Errorf("create certificate: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(certFile), 0o755); err != nil {
		return fmt.Errorf("create cert dir: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(keyFile), 0o700); err != nil {
		return fmt.Errorf("create key dir: %w", err)
	}

	if err := writeFileAtomic(certFile, pem.EncodeToMemory(
		&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return fmt.Errorf("write certificate: %w", err)
	}

	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return fmt.Errorf("marshal key: %w", err)
	}
	if err := writeFileAtomic(keyFile, pem.EncodeToMemory(
		&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		// Не оставляем сертификат без ключа: следующий запуск увидел бы
		// половину пары и отказался стартовать.
		_ = os.Remove(certFile)
		return fmt.Errorf("write key: %w", err)
	}
	return nil
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// writeFileAtomic writes through a temp file in the same directory, so a
// crash mid-write cannot leave a truncated key behind.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".tls-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer func() {
		f.Close()
		os.Remove(tmp)
	}()
	if err := f.Chmod(perm); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
