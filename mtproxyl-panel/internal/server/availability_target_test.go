package server

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateAvailabilityOverrideAccepts(t *testing.T) {
	cases := []struct {
		name string
		in   AvailabilityOverride
	}{
		{"пустое — автоопределение", AvailabilityOverride{}},
		{"домен", AvailabilityOverride{Host: "proxy.example.com", Port: 443}},
		{"IPv4", AvailabilityOverride{Host: "203.0.113.10", Port: 8443}},
		{"IPv6", AvailabilityOverride{Host: "2001:db8::1", Port: 443}},
		{"свой SNI", AvailabilityOverride{Host: "1.2.3.4", SNI: "microsoft.com"}},
		{"пробелы обрезаются", AvailabilityOverride{Host: "  proxy.example.com  "}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			in := tc.in
			if err := validateAvailabilityOverride(&in); err != nil {
				t.Errorf("отклонено верное значение: %s", err)
			}
		})
	}
}

func TestValidateAvailabilityOverrideRejects(t *testing.T) {
	cases := []struct {
		name string
		in   AvailabilityOverride
	}{
		{"со схемой", AvailabilityOverride{Host: "https://proxy.example.com"}},
		{"с портом в адресе", AvailabilityOverride{Host: "proxy.example.com:443"}},
		{"с путём", AvailabilityOverride{Host: "proxy.example.com/check"}},
		{"с пробелом внутри", AvailabilityOverride{Host: "proxy example.com"}},
		{"мусорный SNI", AvailabilityOverride{SNI: "http://evil"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			in := tc.in
			if err := validateAvailabilityOverride(&in); err == nil {
				t.Errorf("принято негодное значение %+v", tc.in)
			}
		})
	}
}

func TestValidateAvailabilityOverrideTrimsHost(t *testing.T) {
	in := AvailabilityOverride{Host: "  proxy.example.com  ", SNI: " sni.example.com "}
	if err := validateAvailabilityOverride(&in); err != nil {
		t.Fatalf("неожиданная ошибка: %s", err)
	}
	if in.Host != "proxy.example.com" {
		t.Errorf("Host = %q, ожидалось без пробелов", in.Host)
	}
	if in.SNI != "sni.example.com" {
		t.Errorf("SNI = %q, ожидалось без пробелов", in.SNI)
	}
}

func TestAvailabilityOverrideStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := newAvailabilityOverrideStore(dir)

	if got := s.get(); got.Host != "" || got.Port != 0 || got.SNI != "" {
		t.Fatalf("пустое хранилище вернуло %+v", got)
	}

	want := AvailabilityOverride{Host: "proxy.example.com", Port: 8443, SNI: "microsoft.com"}
	if err := s.set(want); err != nil {
		t.Fatalf("set: %s", err)
	}

	// Переоткрываем: переопределение должно пережить перезапуск панели.
	reopened := newAvailabilityOverrideStore(dir)
	if got := reopened.get(); got != want {
		t.Errorf("после перезапуска %+v, ожидалось %+v", got, want)
	}
}

func TestAvailabilityOverrideStoreClearRestoresAuto(t *testing.T) {
	dir := t.TempDir()
	s := newAvailabilityOverrideStore(dir)

	if err := s.set(AvailabilityOverride{Host: "proxy.example.com", Port: 8443}); err != nil {
		t.Fatalf("set: %s", err)
	}
	// Пустая форма — это «вернуть автоопределение», а не «проверять пустоту».
	if err := s.set(AvailabilityOverride{}); err != nil {
		t.Fatalf("clear: %s", err)
	}

	reopened := newAvailabilityOverrideStore(dir)
	if got := reopened.get(); got.Host != "" || got.Port != 0 || got.SNI != "" {
		t.Errorf("после очистки %+v, ожидалось пустое", got)
	}
}

// Битый файл не должен ронять проверку: автоопределение справится само.
func TestAvailabilityOverrideStoreSurvivesCorruptFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, availabilityOverrideFile), []byte("{не json"), 0o600); err != nil {
		t.Fatalf("подготовка: %s", err)
	}
	s := newAvailabilityOverrideStore(dir)
	if got := s.get(); got.Host != "" {
		t.Errorf("из битого файла прочиталось %+v", got)
	}
}

// Без data_dir переопределение живёт в памяти и не должно падать при записи.
func TestAvailabilityOverrideStoreWithoutDataDir(t *testing.T) {
	s := newAvailabilityOverrideStore("")
	want := AvailabilityOverride{Host: "proxy.example.com"}
	if err := s.set(want); err != nil {
		t.Fatalf("set без data_dir: %s", err)
	}
	if got := s.get(); got != want {
		t.Errorf("get = %+v, ожидалось %+v", got, want)
	}
}
