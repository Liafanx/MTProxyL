# MTProxyL

**MTProxyL** — менеджер Telegram MTProto прокси на базе движка **telemt** (Rust).

Один скрипт. Полный контроль. Всё на русском.

---

## Навигация

- [Установка](#install)
- [Быстрый старт](#quickstart)
- [Что умеет](#features)
- [Основные CLI команды](#cli)
  - [Прокси](#cli-proxy)
  - [Секреты (пользователи)](#cli-secrets)
  - [Настройки](#cli-settings)
  - [Движок Telemt](#cli-engine)
  - [Режим эксперта](#cli-expert)
  - [NFT SYN Limiter](#cli-nft)
  - [Безопасность](#cli-security)
  - [Мониторинг](#cli-monitoring)
  - [Бэкапы и обновления](#cli-backup)
  - [Система](#cli-system)
  - [Tune (быстрый тюнинг)](#cli-tune)
- [NFT SYN Limiter — подробнее](#nft-details)
- [NFT Smart By-MEKO — подробнее](#nft-smart)
- [iOS фиксы](#ios-fixes)
- [Режим эксперта — подробнее](#expert-details)
- [Модульная архитектура](#architecture)
- [Требования](#requirements)
- [Удаление](#uninstall)

---

<a id="install"></a>

## Установка

```bash
wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh
```

После установки запускается мастер настройки.  
Для повторного входа в меню:

```bash
mtproxyl
```

> При первой установке скрипт предлагает включить **NFT Smart By-MEKO** — рекомендуемый режим с автоматическим разделением iOS/Android и быстрым reconnect.

---

<a id="quickstart"></a>

## Быстрый старт

1. Запустите установку:
   ```bash
   wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh
   ```

2. Следуйте мастеру настройки — выберите порт, домен, IP, режим NFT

3. Получите ссылку на прокси (выводится после установки) или:
   ```bash
   mtproxyl secret link
   ```

4. Откройте ссылку в Telegram — готово!

> Один порт для **всех** клиентов (iOS, Android, Desktop) — при Smart режиме дополнительных настроек не требуется.

---

<a id="features"></a>

## Что умеет

### Управление прокси
- Установка, запуск, остановка, перезапуск
- Docker-контейнер с telemt (Rust) — готовый образ из GHCR или сборка из исходников
- Горячая перезагрузка конфига без обрыва соединений
- Автозапуск через systemd

### Управление пользователями
- Добавление / удаление / ротация секретов
- Лимиты: макс. соединений, IP, квота трафика, срок действия
- Клонирование, переименование, смена ключа
- Экспорт / импорт секретов
- Ссылки для Telegram

### Движок Telemt
- Просмотр списка всех версий с GitHub
- Обновление до любой версии
- Откат к предыдущей
- Пересборка из исходников

### Режим эксперта
- Каталог **всех** параметров telemt config.toml с описаниями, default и диапазонами
- Поддержка секций: general, general.modes, general.links, general.telemetry, network, server, server.listeners, server.conntrack_control, server.api, timeouts, censorship, censorship.tls_fetch, access, logging
- Параметры применяются поверх сгенерированного конфига с максимальным приоритетом
- Не теряются при обновлении, перезапуске или переустановке
- Валидация значений перед применением
- Можно открыть override-файл в nano


### NFT SYN Limiter

Два режима на выбор:

**★ Smart By-MEKO** *(рекомендуется)* — интеллектуальное разделение клиентов:
- iOS и Android/Desktop разделяются **автоматически по TTL** на одном порту
- Выбор действия для non-iOS: `icmp-host-unreachable` *(рекомендуется)* / `reject` / `drop`
- `icmp-host-unreachable` — Telegram мгновенно переключается на основное соединение, медиа без задержек
- Один порт для всех клиентов, iOS Fix v2 и client_mss не нужны
- Вдохновлён проектом [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)

**Оптимизация By-MEKO** — системные sysctl-параметры из проекта MTPROTO-FIX-By-MEKO:
- TCP keepalive 45s/15s×3, BBR, расширенные очереди (somaxconn, backlog = 65535)
- Полный откат к исходным значениям ядра при отключении

**Classic** — традиционный SYN limiter:
- Пресеты: жёсткий (`1/s burst 1`) / средний (`1/s burst 3`) / мягкий (`2/s burst 5`)
- Дополнительные правила на другие порты
- Systemd-служба для автозапуска

### iOS фиксы
- **Вариант 1** — TCP keepalive через sysctl (настраиваемые значения, сохранение оригиналов)
- **Вариант 2** — MSS + redirect на отдельный порт *(не нужен при Smart режиме)*

### Безопасность
- Гео-блокировка по странам (ipset + iptables)
- Upstream-маршрутизация (SOCKS5 / SOCKS4 / direct)
- SNI-политика: mask / drop / accept / reject_handshake
- FakeTLS маскировка с выбором домена
- Mask backend на локальный nginx или удалённый сервер

### Бэкапы
- Обычные и зашифрованные (AES-256)
- Восстановление с предложением перезапуска
- Миграция между серверами (export / import)
- Автоочистка старых бэкапов

### Мониторинг
- Персистентный трафик по пользователям — накапливается между перезагрузками прокси
- Отображается раздельно: всего за всё время и текущая сессия
- Детальные метрики движка в рамках (соединения, upstream, ME health, users, security)
- Метрики в реальном времени (live refresh)
- Активные соединения
- Диагностика
- Потоковые логи

---

<a id="cli"></a>

## Основные CLI команды

<a id="cli-proxy"></a>

### Прокси

```bash
mtproxyl start                # Запустить прокси
mtproxyl stop                 # Остановить прокси
mtproxyl restart              # Перезапустить прокси
mtproxyl status               # Статус (текст)
mtproxyl status --json        # Статус (JSON для скриптов)
mtproxyl logs                 # Потоковые логи контейнера (Ctrl+C для остановки)
```

<a id="cli-secrets"></a>

### Секреты (пользователи)

```bash
mtproxyl secret add alice              # Добавить пользователя
mtproxyl secret remove alice           # Удалить пользователя
mtproxyl secret list                   # Список всех секретов с трафиком
mtproxyl secret rotate alice           # Сгенерировать новый ключ
mtproxyl secret enable alice           # Включить секрет
mtproxyl secret disable alice          # Выключить секрет
mtproxyl secret link alice             # Получить ссылку tg://
mtproxyl secret clone alice bob        # Клонировать секрет с лимитами
mtproxyl secret rename alice bob       # Переименовать
mtproxyl secret limits alice           # Показать лимиты
mtproxyl secret setlimits alice 100 5 10G 2026-12-31  # Установить лимиты
```

<a id="cli-settings"></a>

### Настройки

```bash
mtproxyl port 443                      # Изменить порт прокси
mtproxyl port                          # Показать текущий порт
mtproxyl ip auto                       # Сбросить IP на автоопределение
mtproxyl ip 1.2.3.4                    # Установить свой IP
mtproxyl domain cloudflare.com         # Установить FakeTLS домен
mtproxyl mask-backend 127.0.0.1:8443   # Установить mask backend
mtproxyl sni-policy mask               # Установить SNI-политику (mask/drop/accept/reject_handshake)
mtproxyl config                        # Показать текущий config.toml
```

<a id="cli-engine"></a>

### Движок Telemt

```bash
mtproxyl engine status                 # Текущая установленная версия
mtproxyl engine list                   # Все доступные версии на GitHub
mtproxyl engine update                 # Интерактивный выбор версии для обновления
mtproxyl engine update 3.4.18          # Обновить до конкретной версии
mtproxyl engine rollback               # Откатить к предыдущей установленной версии
mtproxyl engine rebuild                # Принудительно пересобрать образ из исходников
```

<a id="cli-expert"></a>

### Режим эксперта

```bash
mtproxyl expert set censorship mask_relay_max_bytes 5242880    # Добавить override
mtproxyl expert set server client_mss tspu                      # MSS
mtproxyl expert set general rst_on_close errors                 # SO_LINGER(0) при ошибках
mtproxyl expert set timeouts client_handshake 120               # Увеличить handshake timeout
mtproxyl expert list                                            # Показать все override
mtproxyl expert clear mask_relay_max_bytes                      # Удалить один override
mtproxyl expert clear all                                       # Удалить все override
mtproxyl expert edit                                            # Открыть override-файл в nano
```

<a id="cli-nft"></a>

### NFT SYN Limiter

```bash
# Smart By-MEKO (рекомендуется)
mtproxyl nft smart            # Включить Smart режим (интерактивно)
mtproxyl nft preset smart     # Включить Smart с параметрами по умолчанию

# Classic режим
mtproxyl nft preset hard      # Пресет: жёсткий Classic (1/s burst 1)
mtproxyl nft preset medium    # Пресет: средний Classic (1/s burst 3)
mtproxyl nft preset soft      # Пресет: мягкий Classic (2/s burst 5)

# Общее
mtproxyl nft apply            # Применить текущие NFT правила
mtproxyl nft remove           # Удалить NFT правила
mtproxyl nft service          # Установить systemd-службу (автозапуск)
mtproxyl nft drop             # Счётчик правил (live)

# iOS фиксы (Classic режим)
mtproxyl nft ios1             # Включить iOS Fix v1 (TCP keepalive)
mtproxyl nft ios1-off         # Откатить iOS Fix v1
mtproxyl nft ios2             # Включить iOS Fix v2 (MSS + redirect)
mtproxyl nft ios2-off         # Откатить iOS Fix v2

# Дополнительные правила
mtproxyl nft extra-add 8443   # Доп. правило на порт 8443
mtproxyl nft extra-rm 1       # Удалить доп. правило #1
```

<a id="cli-security"></a>

### Безопасность

```bash
mtproxyl geoblock add ir      # Заблокировать страну (IR = Иран)
mtproxyl geoblock add cn      # Заблокировать страну (CN = Китай)
mtproxyl geoblock remove ir   # Разблокировать страну
mtproxyl geoblock list        # Список заблокированных стран
mtproxyl geoblock clear       # Очистить все блокировки
mtproxyl upstream list        # Список upstream-маршрутов
mtproxyl upstream add warp socks5 127.0.0.1:40000        # Добавить SOCKS5 upstream
mtproxyl upstream remove warp                             # Удалить upstream
mtproxyl upstream test warp                               # Проверить upstream
```

<a id="cli-monitoring"></a>

### Мониторинг

```bash
mtproxyl traffic              # Трафик по пользователям
mtproxyl connections          # Активные соединения (детально по пользователям)
mtproxyl metrics              # Метрики движка (соединения, upstream, ME health)
mtproxyl metrics live 5       # Метрики в реальном времени (обновление каждые 5с)
mtproxyl logs                 # Потоковые логи контейнера
mtproxyl health               # Диагностика (Docker, контейнер, метрики, секреты)
mtproxyl info                 # Информация о сервере (ОС, ядро, прокси)
```

<a id="cli-backup"></a>

### Бэкапы и обновления

```bash
mtproxyl backup               # Создать бэкап
mtproxyl backup --encrypt     # Создать зашифрованный бэкап (AES-256)
mtproxyl restore file.tar.gz  # Восстановить из бэкапа
mtproxyl update               # Проверить и установить обновления MTProxyL
```

<a id="cli-system"></a>

### Система

```bash
mtproxyl install              # Запустить мастер установки
mtproxyl menu                 # Открыть интерактивное меню
mtproxyl uninstall            # Полное удаление
mtproxyl version              # Показать версию
mtproxyl help                 # Справка по командам
```

<a id="cli-tune"></a>

### Tune (быстрый тюнинг)

```bash
mtproxyl tune list            # Список доступных параметров для быстрого тюнинга
mtproxyl tune get             # Показать текущие значения
mtproxyl tune set tg_connect 30                    # Установить таймаут подключения к DC
mtproxyl tune set client_handshake 120             # Установить таймаут handshake
mtproxyl tune set client_keepalive 120             # Установить таймаут keepalive
mtproxyl tune clear tg_connect                     # Вернуть параметр к значению по умолчанию
mtproxyl tune clear all                            # Очистить все быстрые настройки
```

---

<a id="nft-details"></a>

## NFT SYN Limiter — подробнее

MTProxyL поддерживает два режима NFT SYN Limiter: **Smart By-MEKO** и **Classic**.

### Classic режим

Традиционное ограничение входящих SYN-пакетов отдельно для каждого IP клиента:

```nft
tcp dport <PORT>
tcp flags & (syn | ack) == syn
meter { ip saddr timeout 60s limit rate over 1/second burst 1 packets }
counter drop
```

Каждый клиентский IP получает **свой независимый bucket** — один шумный клиент не мешает остальным.

#### Пресеты Classic

| Пресет | Rate | Burst | Описание |
|--------|------|-------|----------|
| **Жёсткий** | 1/second | 1 | Строгое ограничение |
| **Средний** | 1/second | 3 | Разрешает кратковременный burst |
| **Мягкий** | 2/second | 5 | Для серверов с большим числом клиентов |

#### Предупреждение

Если клиенты за CGNAT (общий IP) или VPN — жёсткий режим может давать ложные срабатывания. В таких случаях используйте средний или мягкий пресет, либо переключитесь на Smart режим.

---

<a id="nft-smart"></a>

## ★ NFT Smart By-MEKO — подробнее

> Вдохновлён проектом [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO) — спасибо автору за идею.

**Smart By-MEKO** — рекомендуемый режим, который решает главную проблему классического SYN limiter: долгое подключение и конфликт между iOS и другими клиентами.

### Как работает

Вместо одного правила для всех — четыре точечных правила через nftables:

```nft
# 1. iOS SYN (TTL < 65, length 64) → мягкий лимит → accept
tcp dport PORT tcp flags syn ip ttl < 65 meta length 64
  meter ios { ip saddr limit rate 15/second burst 30 } accept

# 2. iOS SYN сверх лимита → мгновенный RST
tcp dport PORT tcp flags syn ip ttl < 65 meta length 64
  reject with tcp reset

# 3. Остальные SYN → строгий лимит → accept
tcp dport PORT tcp flags syn
  meter other { ip saddr limit rate 54/minute burst 1 } accept

# 4. Остальные SYN сверх лимита → настраиваемое действие
tcp dport PORT tcp flags syn
  reject with icmp type host-unreachable  # по умолчанию
  # или: reject with tcp reset
  # или: drop
```

### Три ключевых отличия от Classic

**Разделение iOS и остальных клиентов по TTL**

iOS отправляет SYN с TTL=64 (то есть TTL < 65 у сервера) и длиной пакета ровно 64 байта. Это позволяет выделить iOS-клиентов **без второго порта**:

| Клиент | TTL | Пакет | Лимит |
|--------|-----|-------|-------|
| iOS | < 65 | 64 байта | 15/sec burst 30 — мягкий |
| Android / Desktop / macOS | ≥ 65 | любой | 54/min burst 1 — строгий |

**REJECT вместо DROP**

| Поведение | Classic DROP | Smart REJECT |
|-----------|-------------|--------------|
| Клиент получает | ничего | RST мгновенно |
| Ожидание клиента | 3-5 сек (TCP timeout) | ~0 мс |
| Время подключения | 10-20 сек | **3-8 сек** |

При DROP клиент не знает что пакет отброшен и ждёт TCP retransmission timeout. При REJECT с `tcp-reset` клиент получает RST и переподключается немедленно.

**54/minute вместо 1/second**

iptables/nftables `hashlimit` не поддерживает дробные секунды. 54/минута = ~1.1 сек между SYN. Небольшой запас в 100мс исключает погрешность при мгновенном REJECT — клиент успевает переподключиться не нарушая лимит.

### Что не нужно при Smart режиме

- **iOS Fix v2** (MSS + отдельный порт 4443) — Smart разделяет iOS и Android на одном порту
- **client_mss** в конфиге telemt — MSS через nftables не применяется
- Разные ссылки для iOS и Android — один порт, одна ссылка для всех

### Включить Smart режим

```bash
# Интерактивно с описанием
mtproxyl nft smart

# Или через пресет
mtproxyl nft preset smart
```

Или в интерактивном меню: `[7] → [s]`

### Настройка параметров Smart режима

Через меню `[7] → [4]` можно изменить:

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| iOS Rate | 15/second | Лимит SYN для iOS клиентов |
| iOS Burst | 30 | Burst для iOS |
| Other Rate | 54/minute | Лимит SYN для Android/Desktop |
| Other Burst | 1 | Burst для Android/Desktop |
| Other Action | icmp-host-unreachable | Действие при превышении лимита non-iOS |
| Timeout | 60s | Время жизни записи в meter |

### Systemd-служба

```bash
mtproxyl nft service    # Установить и включить автозапуск
```

Проверить:

```bash
systemctl status mtproxyl-syn-limit.service --no-pager
nft list table inet mtproxyl_limit
```

---

<a id="ios-fixes"></a>

## iOS фиксы

> При использовании **Smart By-MEKO** iOS Fix v2 не нужен — iOS и Android разделяются автоматически на одном порту.

### Вариант 1 — TCP keepalive

Ускоряет обнаружение мёртвых сокетов через `sysctl`. Подходит когда iOS-клиенты после фона/сна не могут нормально переподключиться. Совместим с обоими режимами NFT.

По умолчанию: `time=60, intvl=15, probes=3` → обнаружение ~105 сек.

Значения можно менять. Исходные системные значения сохраняются и восстанавливаются при откате.

```bash
mtproxyl nft ios1          # Включить
mtproxyl nft ios1-off      # Откатить
```

### Вариант 2 — MSS + redirect *(только Classic режим)*

Создаёт отдельный порт для iOS (по умолчанию `4443`) с MSS=92 и прозрачным редиректом на основной порт. Актуален только при Classic режиме NFT.

```bash
mtproxyl nft ios2          # Включить
mtproxyl nft ios2-off      # Откатить
```

> При включении iOS Fix v2 убедитесь, что в конфиге **нет** `client_mss`.

iOS-пользователям нужно заменить **только порт** в ссылке:

```
было:  tg://proxy?server=IP&port=443&secret=...
стало: tg://proxy?server=IP&port=4443&secret=...
```

---

### Оптимизация системы By-MEKO

Набор sysctl-параметров из проекта [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO). Доступен в меню `[7] → [m]`.

| Параметр | Значение | Эффект |
|----------|---------|--------|
| `tcp_keepalive_time` | 45 | Обнаружение мёртвых сокетов за ~90 сек |
| `tcp_keepalive_intvl` | 15 | Интервал keepalive-проб |
| `tcp_keepalive_probes` | 3 | Количество проб |
| `net.core.somaxconn` | 65535 | Очередь accept |
| `tcp_max_syn_backlog` | 65535 | Очередь SYN |
| `netdev_max_backlog` | 65535 | Очередь netdev |
| `tcp_fastopen` | 3 | TCP Fast Open |
| `fs.file-max` | 2097152 | Лимит файловых дескрипторов |
| `default_qdisc` | fq | Планировщик очереди |
| `tcp_congestion_control` | bbr | Алгоритм управления перегрузкой |

Все текущие значения ядра сохраняются перед применением и полностью восстанавливаются при откате или удалении MTProxyL.

---

<a id="expert-details"></a>

## Режим эксперта — подробнее

Режим эксперта позволяет управлять **любыми** параметрами telemt `config.toml` через удобное меню с каталогом параметров.

### Как работает

1. Вы выбираете **раздел** (`general`, `server`, `timeouts`, `censorship`, `network`, `server.api`, `access`, ...)
2. Выбираете **параметр** из каталога
3. Видите:
   - описание
   - тип данных
   - значение по умолчанию
   - поддержка hot-reload (`✔/✘`)
   - допустимые значения / диапазон
4. Вводите новое значение — оно проходит валидацию
5. Override сохраняется в отдельный файл `expert.conf`

### Приоритет

```
config.toml (MTProxyL) → tunings.conf → expert.conf
```

**Expert override имеет максимальный приоритет** — он применяется последним и перезаписывает любые сгенерированные значения.

### Override-файл

Формат `expert.conf`:

```
section|key|value
censorship|mask_relay_timeout_ms|120000
general|log_level|debug
server|client_mss|tspu
```

Можно редактировать вручную:

```bash
mtproxyl expert edit
```

При сохранении файл проходит валидацию — невалидные записи предупреждаются.

### Примеры

```bash
# Увеличить handshake timeout для медленных клиентов
mtproxyl expert set timeouts client_handshake 120

# Включить RST вместо FIN для неудачных handshake
mtproxyl expert set general rst_on_close errors

# Увеличить таймаут mask relay
mtproxyl expert set censorship mask_relay_timeout_ms 120000

# Включить компактный ServerHello
mtproxyl expert set censorship serverhello_compact true

# Посмотреть все override
mtproxyl expert list

# Удалить один override
mtproxyl expert clear rst_on_close

# Удалить все override
mtproxyl expert clear all
```

---

<a id="architecture"></a>

## Модульная архитектура

Вместо одного скрипта на 8000+ строк — модульная структура:

```
/opt/mtproxyl/
├── mtproxyl.sh                  # Главный скрипт + CLI dispatcher
├── lib/
│   ├── colors.sh                # UI: цвета, символы
│   ├── utils.sh                 # Утилиты, валидация, CLI-обработчики, автообновление
│   ├── settings.sh              # Сохранение / загрузка настроек
│   ├── secrets.sh               # Управление секретами
│   ├── config.sh                # Генерация config.toml + tune
│   ├── docker.sh                # Docker: сборка, запуск, контейнер
│   ├── engine.sh                # Версии telemt: list / update / rollback
│   ├── traffic.sh               # Метрики, трафик, диагностика
│   ├── geoblock.sh              # Гео-блокировка
│   ├── upstream.sh              # Upstream-маршрутизация
│   ├── backup.sh                # Бэкапы, миграция
│   ├── nft.sh                   # NFT limiter (Classic + Smart By-MEKO) + iOS фиксы
│   ├── expert_catalog.sh        # Каталог параметров telemt
│   ├── expert_mode.sh           # Режим эксперта: UI + валидация + override
│   ├── tui_main.sh              # Главное меню
│   ├── tui_proxy.sh             # Подменю: прокси
│   ├── tui_secrets.sh           # Подменю: секреты
│   ├── tui_links.sh             # Подменю: ссылки и QR
│   ├── tui_settings.sh          # Подменю: настройки
│   ├── tui_security.sh          # Подменю: безопасность
│   ├── tui_traffic.sh           # Подменю: трафик и метрики
│   ├── tui_engine.sh            # Подменю: движок
│   ├── tui_backup.sh            # Подменю: обновления и бэкапы
│   ├── tui_nft.sh               # Подменю: NFT limiter (Classic + Smart) + iOS
│   └── install.sh               # Установщик + деинсталлятор
├── mtproxy/
│   └── config.toml              # Сгенерированный конфиг telemt
├── settings.conf                # Настройки MTProxyL
├── secrets.conf                 # Секреты пользователей
├── expert.conf                  # Expert override (поверх config.toml)
├── tunings.conf                 # Быстрый тюнинг движка
├── nft-rules.conf               # Настройки NFT limiter (режим + параметры)
└── backups/                     # Бэкапы
```

---

<a id="requirements"></a>

## Требования

| Требование | Детали |
|-----------|--------|
| **ОС** | Ubuntu, Debian, CentOS, RHEL, Fedora, Rocky, AlmaLinux, Alpine |
| **Docker** | Устанавливается автоматически |
| **nftables** | Устанавливается автоматически при первом использовании NFT limiter |
| **RAM** | 256 МБ минимум |
| **Доступ** | Требуется root |
| **Bash** | 4.2+ |

---

<a id="uninstall"></a>

## Удаление

Из интерактивного меню: клавиша `u`

Или через CLI:

```bash
mtproxyl uninstall
```

При удалении скрипт предлагает:
- Сохранить секреты перед удалением

Docker **не удаляется**. Глобальный Docker build cache **не чистится**.

---

## Благодарности

- **[MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)** — идея Smart режима NFT: разделение iOS/Android по TTL+Length, REJECT вместо DROP, оптимизация системных параметров sysctl

---

## Лицензия

MIT

---

MTProxyL by LiafanX · [GitHub](https://github.com/Liafanx/MTProxyL)
