package mtproxylctl

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/Liafanx/mtproxyl-panel/internal/config"
)

// Архив — двоичный gzip. Если по пути к браузеру его хоть где-то тронут
// (например, срежут ANSI, как в остальных командах), скачанный файл
// не распакуется.
func TestReadBackupPreservesBinary(t *testing.T) {
	dir := t.TempDir()

	var payload bytes.Buffer
	zw := gzip.NewWriter(&payload)
	// Внутрь кладём в том числе байты, похожие на ANSI-escape.
	original := append([]byte("настройки\x00\x1b[0;32m двоичные\xff\xfe данные\n"), 0x1b, '[', 'K')
	if _, err := zw.Write(original); err != nil {
		t.Fatal(err)
	}
	zw.Close()

	archive := filepath.Join(dir, "mtproxyl-20260802-165612.tar.gz")
	if err := os.WriteFile(archive, payload.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	script := filepath.Join(dir, "mtproxyl.sh")
	body := "#!/bin/bash\n[ \"$1\" = backup ] && [ \"$2\" = cat ] && exec cat " + archive + "\nexit 1\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: script, UseSudo: false})
	got, err := c.ReadBackup(context.Background(), "mtproxyl-20260802-165612.tar.gz")
	if err != nil {
		t.Fatalf("чтение не удалось: %s", err)
	}
	if !bytes.Equal(got, payload.Bytes()) {
		t.Fatalf("байты изменились: было %d, стало %d", len(payload.Bytes()), len(got))
	}

	// И архив после этого действительно распаковывается.
	zr, err := gzip.NewReader(bytes.NewReader(got))
	if err != nil {
		t.Fatalf("gzip не читается: %s", err)
	}
	round, err := io.ReadAll(zr)
	if err != nil {
		t.Fatalf("распаковка не удалась: %s", err)
	}
	if !bytes.Equal(round, original) {
		t.Fatal("содержимое после распаковки не совпало")
	}
	t.Logf("прошло %d байт без искажений", len(got))
}

func TestReadBackupRejectsBadName(t *testing.T) {
	c := New(config.MtproxylConfig{Enabled: true, ScriptPath: "/bin/true", UseSudo: false})
	for _, name := range []string{"../../etc/shadow", "/etc/shadow", "evil.tar.gz", ""} {
		if _, err := c.ReadBackup(context.Background(), name); err == nil {
			t.Errorf("имя %q должно отвергаться", name)
		}
	}
}
