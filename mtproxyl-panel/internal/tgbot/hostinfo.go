package tgbot

import (
	"context"
	"net"
	"slices"
	"sync"
	"time"

	"github.com/Liafanx/mtproxyl-panel/internal/globalping"
)

const (
	// publicIPTTL — как долго держим внешний адрес сервера. Рендер бывает чаще
	// проверок (кнопка «Обновить»), а лезть за IP на каждую отрисовку значит
	// дёргать чужие сервисы без повода. Переезд на новый адрес — событие
	// редкое, десять минут задержки его не спрячут.
	publicIPTTL = 10 * time.Minute

	// lookupTimeout ограничивает резолв домена цели. IP в сообщении — приятная
	// подробность, а не повод задержать сам вердикт.
	lookupTimeout = 3 * time.Second
)

// HostInfo — адресная часть сообщения: куда стучались зонды и тот ли это
// сервер, на котором работает панель.
type HostInfo struct {
	// Addrs — A/AAAA-записи домена цели. Пусто, если цель задана IP-литералом
	// (резолвить нечего) или если резолв не удался.
	Addrs []string
	// ServerIP — внешний адрес самого сервера. Пусто, если определить не вышло.
	ServerIP string
	// Mismatch — домен цели не ведёт на этот сервер. Частая причина
	// «прокси здоров, а не работает»: переехали на новый VPS и забыли DNS.
	Mismatch bool
}

// Resolver собирает HostInfo. Функции резолва вынесены в поля, чтобы тесты
// обходились без сети.
type Resolver struct {
	lookup   func(ctx context.Context, host string) ([]string, error)
	publicIP func(ctx context.Context) (string, error)

	mu        sync.Mutex
	cachedIP  string
	fetchedAt time.Time
	now       func() time.Time
}

func NewResolver() *Resolver {
	return &Resolver{
		lookup: func(ctx context.Context, host string) ([]string, error) {
			return net.DefaultResolver.LookupHost(ctx, host)
		},
		publicIP: globalping.PublicIP,
		now:      time.Now,
	}
}

// Describe отвечает на два вопроса: куда ведёт домен цели и где стоит сервер.
// Ни один отказ здесь не считается ошибкой — просто строки не будет: сообщение
// о доступности важнее украшений к нему.
func (r *Resolver) Describe(ctx context.Context, host string) HostInfo {
	var info HostInfo

	if host != "" && net.ParseIP(host) == nil {
		lookupCtx, cancel := context.WithTimeout(ctx, lookupTimeout)
		addrs, err := r.lookup(lookupCtx, host)
		cancel()
		if err == nil {
			info.Addrs = addrs
		}
	}

	info.ServerIP = r.serverIP(ctx)

	// Сравниваем, только когда известно и то и другое. Цель-IP-литерал сюда не
	// попадает: Addrs пуст, и «расхождения» с самим собой не бывает.
	if info.ServerIP != "" && len(info.Addrs) > 0 {
		info.Mismatch = !slices.Contains(info.Addrs, info.ServerIP)
	}
	return info
}

func (r *Resolver) serverIP(ctx context.Context) string {
	r.mu.Lock()
	if r.cachedIP != "" && r.now().Sub(r.fetchedAt) < publicIPTTL {
		ip := r.cachedIP
		r.mu.Unlock()
		return ip
	}
	r.mu.Unlock()

	ip, err := r.publicIP(ctx)
	if err != nil || ip == "" {
		// Отдаём просроченный адрес, если он есть: устаревший ответ полезнее
		// пустой строки, а сервисы определения IP регулярно недоступны.
		r.mu.Lock()
		defer r.mu.Unlock()
		return r.cachedIP
	}

	r.mu.Lock()
	r.cachedIP = ip
	r.fetchedAt = r.now()
	r.mu.Unlock()
	return ip
}
