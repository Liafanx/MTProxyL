package tgbot

import (
	"context"
	"errors"
	"testing"
	"time"
)

func testResolver(addrs []string, lookupErr error, ip string, ipErr error) (*Resolver, *int) {
	ipCalls := 0
	r := &Resolver{
		lookup: func(context.Context, string) ([]string, error) {
			return addrs, lookupErr
		},
		publicIP: func(context.Context) (string, error) {
			ipCalls++
			return ip, ipErr
		},
		now: time.Now,
	}
	return r, &ipCalls
}

func TestDescribeResolvesDomain(t *testing.T) {
	r, _ := testResolver([]string{"203.0.113.10"}, nil, "203.0.113.10", nil)

	info := r.Describe(context.Background(), "proxy.example.com")

	if len(info.Addrs) != 1 || info.Addrs[0] != "203.0.113.10" {
		t.Errorf("Addrs = %v", info.Addrs)
	}
	if info.ServerIP != "203.0.113.10" {
		t.Errorf("ServerIP = %q", info.ServerIP)
	}
	if info.Mismatch {
		t.Error("Mismatch = true при совпадающих адресах")
	}
}

// Цель задана IP-литералом: резолвить нечего, и «расхождения» с самим собой
// быть не может.
func TestDescribeSkipsLookupForIPLiteral(t *testing.T) {
	lookups := 0
	r := &Resolver{
		lookup: func(context.Context, string) ([]string, error) {
			lookups++
			return []string{"1.1.1.1"}, nil
		},
		publicIP: func(context.Context) (string, error) { return "203.0.113.10", nil },
		now:      time.Now,
	}

	info := r.Describe(context.Background(), "203.0.113.10")

	if lookups != 0 {
		t.Errorf("резолв вызван %d раз для IP-литерала", lookups)
	}
	if len(info.Addrs) != 0 {
		t.Errorf("Addrs = %v, ожидалось пусто", info.Addrs)
	}
	if info.Mismatch {
		t.Error("Mismatch = true для цели-IP")
	}
}

func TestDescribeFlagsMismatch(t *testing.T) {
	r, _ := testResolver([]string{"203.0.113.10"}, nil, "198.51.100.7", nil)

	info := r.Describe(context.Background(), "proxy.example.com")

	if !info.Mismatch {
		t.Error("Mismatch = false, хотя домен ведёт на другой адрес")
	}
}

// Домен с несколькими A-записями: наш адрес среди них — расхождения нет.
func TestDescribeMultipleAddressesIncludingServer(t *testing.T) {
	r, _ := testResolver([]string{"198.51.100.7", "203.0.113.10"}, nil, "203.0.113.10", nil)

	if r.Describe(context.Background(), "proxy.example.com").Mismatch {
		t.Error("Mismatch = true, хотя адрес сервера есть среди A-записей")
	}
}

// Ни резолв, ни определение IP не должны мешать сообщению: не вышло — просто
// строки не будет.
func TestDescribeSurvivesFailures(t *testing.T) {
	r, _ := testResolver(nil, errors.New("SERVFAIL"), "", errors.New("никто не ответил"))

	info := r.Describe(context.Background(), "proxy.example.com")

	if len(info.Addrs) != 0 || info.ServerIP != "" || info.Mismatch {
		t.Errorf("при отказах ожидался пустой HostInfo, получено %+v", info)
	}
}

func TestServerIPIsCached(t *testing.T) {
	r, calls := testResolver(nil, errors.New("не нужно"), "203.0.113.10", nil)

	for i := 0; i < 3; i++ {
		r.Describe(context.Background(), "203.0.113.10")
	}

	if *calls != 1 {
		t.Errorf("внешний IP запрошен %d раз, ожидался 1: кэш не работает", *calls)
	}
}

func TestServerIPCacheExpires(t *testing.T) {
	r, calls := testResolver(nil, errors.New("не нужно"), "203.0.113.10", nil)
	base := time.Now()
	r.now = func() time.Time { return base }

	r.Describe(context.Background(), "203.0.113.10")
	r.now = func() time.Time { return base.Add(publicIPTTL + time.Minute) }
	r.Describe(context.Background(), "203.0.113.10")

	if *calls != 2 {
		t.Errorf("после истечения TTL адрес запрошен %d раз, ожидалось 2", *calls)
	}
}

// Сервисы определения IP регулярно недоступны. Просроченный адрес полезнее
// пустой строки: сервер редко переезжает посреди аварии.
func TestServerIPFallsBackToStaleValue(t *testing.T) {
	ip := "203.0.113.10"
	var fail bool
	r := &Resolver{
		lookup: func(context.Context, string) ([]string, error) { return nil, errors.New("не нужно") },
		publicIP: func(context.Context) (string, error) {
			if fail {
				return "", errors.New("никто не ответил")
			}
			return ip, nil
		},
		now: time.Now,
	}
	base := time.Now()
	r.now = func() time.Time { return base }

	r.Describe(context.Background(), "203.0.113.10")
	fail = true
	r.now = func() time.Time { return base.Add(publicIPTTL + time.Minute) }

	if got := r.Describe(context.Background(), "203.0.113.10").ServerIP; got != ip {
		t.Errorf("ServerIP = %q, ожидался просроченный %q", got, ip)
	}
}
