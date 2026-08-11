package server

import "testing"

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
