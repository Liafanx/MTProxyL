# MTProxyL

**MTProxyL** — менеджер Telegram MTProto прокси на базе движка **telemt** (Rust).

Один скрипт. Полный контроль. Всё на русском.

---

## Навигация

- [Установка](#install)
- [Быстрый старт](#quickstart)
- [⚠️ Важно: выбор домена для FakeTLS](#pq-warning)
- [Что умеет](#features)
- [Основные CLI команды](#cli)
  - [Прокси](#cli-proxy)
  - [Секреты (пользователи)](#cli-secrets)
  - [Настройки](#cli-settings)
  - [Движок Telemt](#cli-engine)
  - [Режим эксперта](#cli-expert)
  - [NFT SYN Limiter](#cli-nft)
  - [Selfmask](#cli-selfmask)
  - [PQ проверка](#cli-pqcheck)
  - [Безопасность](#cli-security)
  - [Мониторинг](#cli-monitoring)
  - [Бэкапы и обновления](#cli-backup)
  - [Система](#cli-system)
  - [Tune (быстрый тюнинг)](#cli-tune)
- [NFT SYN Limiter — подробнее](#nft-details)
- [NFT Smart By-MEKO — подробнее](#nft-smart)
- [Selfmask — подробнее](#selfmask-details)
- [iOS фиксы](#ios-fixes)
- [Режим эксперта — подробнее](#expert-details)
- [Модульная архитектура](#architecture)
- [Требования](#requirements)
- [Удаление](#uninstall)
- [Благодарности](#thanks)
- [Поддержать автора](#donate)

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

<a id="pq-warning"></a>

## ⚠️ Важно: выбор домена для FakeTLS

> **Используя любой вариант SYN-ограничений (Smart By-MEKO, Classic, встроенный synlimit telemt), убедитесь что домен для FakeTLS поддерживает постквантовый гибридный алгоритм обмена ключами (X25519MLKEM768 + классическая эллиптическая кривая).**
>
> Если выбранный домен **не поддерживает** PQ — с высокой вероятностью после попытки подключения с iOS прилетит блокировка и подключение не удастся (бесконечное «Соединение…»).
>
> **Как проверить:**
> - встроенная утилита: `mtproxyl pq-check ваш-домен.com`
> - или бот: [@Sni_checker_bot](https://t.me/Sni_checker_bot)
>
> - 🟢 **сервер принимает X25519MLKEM768** — домен подходит
> - 🟡 **PQ нет, но Peer Temp Key не X25519** — маркера нет, можно использовать
> - 🔴 **PQ не поддерживается** + `Peer Temp Key = X25519` — **iOS не сможет подключиться**
>
> **Если у вас свой домен** — используйте **Selfmask**, который поднимает локальный PQ nginx с поддержкой X25519MLKEM768. В этом случае ваш домен **гарантированно** будет поддерживать PQ.

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
- Валидация значений перед применением

### NFT SYN Limiter

**★ Smart By-MEKO** *(рекомендуется)* — интеллектуальное разделение клиентов:
- Два метода определения iOS: **TCP fingerprint** *(рекомендуется)* и TTL+Length
- iOS пропускается без ограничений по умолчанию, лимит Other включён
- Лимиты iOS и Other можно включать/отключать раздельно
- Выбор действия для non-iOS: `icmp-host-unreachable` / `reject` / `drop`
- Один порт для всех клиентов
- Автоопределение `fake_cert_len` при выборе домена
- Вдохновлён проектом [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)

**Classic** — традиционный SYN limiter с пресетами.

**Оптимизация By-MEKO** — TCP keepalive, BBR, расширенные очереди.

### Selfmask — маскировка под реальный сайт

- Поднимает **PQ nginx** (собранный с OpenSSL 3.5.7) на вашем домене
- Поддержка **X25519MLKEM768** — iOS клиенты работают без блокировок
- Автоматический **Let's Encrypt** сертификат с автопродлением
- 3 встроенных шаблона + возможность указать свой
- Не трогает системный nginx и OpenSSL
- CLI: `mtproxyl selfmask setup`

### Проверка доменов на PQ-совместимость

- Встроенная утилита проверки любого домена на поддержку X25519MLKEM768
- Показывает PQ-подключение, обычное TLS, Peer Temp Key, маркер
- CLI: `mtproxyl pq-check домен.com`

### Безопасность
- Гео-блокировка по странам (ipset + iptables)
- Upstream-маршрутизация (SOCKS5 / SOCKS4 / direct)
- SNI-политика: mask / drop / accept / reject_handshake
- FakeTLS маскировка с выбором домена

### Бэкапы
- Обычные и зашифрованные (AES-256)
- Миграция между серверами
- Автоочистка старых бэкапов

### Мониторинг
- Персистентный трафик — накапливается между перезагрузками прокси
- Детальные метрики движка
- Метрики в реальном времени
- Активные соединения, диагностика, логи

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
mtproxyl logs                 # Потоковые логи контейнера
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
mtproxyl secret setlimits alice 100 5 10G 2026-12-31
```

<a id="cli-settings"></a>

### Настройки

```bash
mtproxyl port 443                      # Изменить порт прокси
mtproxyl ip auto                       # Сбросить IP на автоопределение
mtproxyl domain cloudflare.com         # Установить FakeTLS домен (авто-подбор fake_cert_len)
mtproxyl mask-backend 127.0.0.1:8443   # Установить mask backend
mtproxyl sni-policy mask               # Установить SNI-политику
mtproxyl config                        # Показать текущий config.toml
```

<a id="cli-engine"></a>

### Движок Telemt

```bash
mtproxyl engine status                 # Текущая версия
mtproxyl engine list                   # Все версии на GitHub
mtproxyl engine update                 # Обновить (интерактивно)
mtproxyl engine update 3.4.18          # Обновить до конкретной версии
mtproxyl engine rollback               # Откатить
mtproxyl engine rebuild                # Пересобрать из исходников
```

<a id="cli-expert"></a>

### Режим эксперта

```bash
mtproxyl expert set censorship mask_relay_max_bytes 5242880
mtproxyl expert set server client_mss tspu
mtproxyl expert list
mtproxyl expert clear all
mtproxyl expert edit
```

<a id="cli-nft"></a>

### NFT SYN Limiter

```bash
mtproxyl nft smart            # Включить Smart режим
mtproxyl nft preset smart     # Smart с параметрами по умолчанию
mtproxyl nft preset hard      # Classic: жёсткий (1/s burst 1)
mtproxyl nft preset medium    # Classic: средний (1/s burst 3)
mtproxyl nft preset soft      # Classic: мягкий (2/s burst 5)
mtproxyl nft apply            # Применить правила
mtproxyl nft remove           # Удалить правила
mtproxyl nft service          # Systemd-служба
mtproxyl nft drop             # Счётчик правил (live)
mtproxyl nft ios1             # iOS Fix v1 (TCP keepalive)
mtproxyl nft ios2             # iOS Fix v2 (MSS + redirect)
mtproxyl nft extra-add 8443   # Доп. правило
```

<a id="cli-selfmask"></a>

### Selfmask

```bash
mtproxyl selfmask status      # Статус selfmask
mtproxyl selfmask setup       # Настроить / переустановить
mtproxyl selfmask verify      # Проверить (nginx, cert, PQ handshake)
mtproxyl selfmask disable     # Отключить selfmask
mtproxyl selfmask menu        # Открыть меню
```

<a id="cli-pqcheck"></a>

### PQ проверка

```bash
mtproxyl pq-check                     # Проверить текущий SNI-домен
mtproxyl pq-check cloudflare.com      # Проверить любой домен
mtproxyl pq-check example.com:8443    # Домен на нестандартном порту
```

<a id="cli-security"></a>

### Безопасность

```bash
mtproxyl geoblock add ir      # Заблокировать страну
mtproxyl geoblock remove ir   # Разблокировать
mtproxyl geoblock list        # Список
mtproxyl upstream list        # Upstream-маршруты
mtproxyl upstream add warp socks5 127.0.0.1:40000
mtproxyl upstream test warp
```

<a id="cli-monitoring"></a>

### Мониторинг

```bash
mtproxyl traffic              # Трафик по пользователям
mtproxyl connections          # Активные соединения
mtproxyl metrics              # Метрики движка
mtproxyl metrics live 5       # Метрики в реальном времени
mtproxyl logs                 # Потоковые логи
mtproxyl health               # Диагностика
mtproxyl info                 # Информация о сервере
```

<a id="cli-backup"></a>

### Бэкапы и обновления

```bash
mtproxyl backup               # Создать бэкап
mtproxyl backup --encrypt     # Зашифрованный бэкап
mtproxyl restore file.tar.gz  # Восстановить
mtproxyl update               # Обновить MTProxyL
```

<a id="cli-system"></a>

### Система

```bash
mtproxyl install              # Мастер установки
mtproxyl menu                 # Интерактивное меню
mtproxyl uninstall            # Полное удаление
mtproxyl version              # Версия
mtproxyl help                 # Справка
```

<a id="cli-tune"></a>

### Tune (быстрый тюнинг)

```bash
mtproxyl tune list
mtproxyl tune set tg_connect 30
mtproxyl tune clear all
```

---

<a id="nft-details"></a>

## NFT SYN Limiter — подробнее

MTProxyL поддерживает два режима NFT SYN Limiter: **Smart By-MEKO** и **Classic**.

### Classic режим

Традиционное ограничение входящих SYN-пакетов с пресетами: жёсткий / средний / мягкий.

---

<a id="nft-smart"></a>

## ★ NFT Smart By-MEKO — подробнее

> Вдохновлён проектом [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)

iOS определяется одним из двух методов:
- **TCP fingerprint** *(рекомендуется)* — по TCP SYN payload
- **TTL+Length** *(устаревший)* — `ip ttl < 65` + `meta length 64`

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| iOS Rate | 15/second | Лимит SYN для iOS |
| iOS Burst | 30 | Burst для iOS |
| iOS Limit | отключён | iOS пропускаются без ограничений (безусловный ACCEPT) |
| Other Rate | 54/minute | Лимит SYN для Android/Desktop |
| Other Burst | 1 | Burst для Other |
| Other Limit | включён | Можно отключить |
| Other Action | icmp-host-unreachable | Действие при превышении |
| iOS Detect | fingerprint | Метод определения iOS |

---

<a id="selfmask-details"></a>

## Selfmask — маскировка под реальный сайт

Selfmask превращает ваш прокси-сервер в полноценный HTTPS-сайт на собственном домене.

### Как работает

```
Telegram клиент → telemt :443 (MTProto)
Браузер / сканер → telemt :443 → mask → PQ nginx 127.0.0.1:8444 → ваш сайт
```

### Что устанавливается

| Компонент | Путь | Описание |
|-----------|------|----------|
| PQ nginx | `/opt/mtproxyl-nginx/sbin/nginx` | nginx 1.28.3 со статическим OpenSSL 3.5.7 |
| PQ OpenSSL | `/opt/mtproxyl-nginx/bin/openssl` | OpenSSL 3.5.7 для PQ-проверок |
| Конфиг nginx | `/opt/mtproxyl-nginx/conf/nginx.conf` | Генерируется автоматически |
| Сайт | `/var/www/mtproxyl-selfmask/` | HTML-заглушка или шаблон |
| Сертификат | `/etc/letsencrypt/live/<домен>/` | Let's Encrypt (автопродление) |
| Служба | `mtproxyl-pq-nginx.service` | Systemd unit |

### Важно

- **Не заменяет** системный nginx и OpenSSL
- Backend работает на **TLS 1.3** с **X25519MLKEM768**
- Ваш домен **гарантированно** поддерживает PQ — iOS клиенты работают без блокировок
- Требуется домен с A-записью на сервер

### Шаблоны сайтов

| Шаблон | Описание |
|--------|----------|
| Простая заглушка | «Сайт временно недоступен» |
| Файловый менеджер | Форма входа (всегда «неверные данные») |
| Cat Runner | Мини-игра: кот прыгает через кактусы |
| Свой URL | Любой `index.html` по ссылке |

### Настройка

```bash
mtproxyl selfmask setup       # Интерактивная настройка
mtproxyl selfmask verify      # Проверка всех компонентов
mtproxyl selfmask status      # Текущее состояние
```

Или через меню: `[4] Настройки → [h] Selfmask`

---

<a id="ios-fixes"></a>

## iOS фиксы

> При использовании **Smart By-MEKO** iOS Fix v2 не нужен.

> ⚠️ Убедитесь что FakeTLS домен поддерживает PQ (X25519MLKEM768). [Подробнее →](#pq-warning)

### Вариант 1 — TCP keepalive

Ускоряет обнаружение мёртвых сокетов через `sysctl`.

### Вариант 2 — MSS + redirect

Отдельный порт для iOS с MSS=92.

### Оптимизация системы By-MEKO

TCP keepalive 45s, BBR, расширенные очереди. Доступна в меню `[7] → [m]`.

---

<a id="expert-details"></a>

## Режим эксперта — подробнее

Управление **любыми** параметрами telemt `config.toml` через каталог с валидацией.

Приоритет: `config.toml → tunings.conf → expert.conf`

---

<a id="architecture"></a>

## Модульная архитектура

```
/opt/mtproxyl/
├── mtproxyl.sh                  # Главный скрипт + CLI dispatcher
├── lib/
│   ├── colors.sh                # UI: цвета, символы
│   ├── utils.sh                 # Утилиты, валидация, CLI-обработчики
│   ├── settings.sh              # Сохранение / загрузка настроек
│   ├── secrets.sh               # Управление секретами
│   ├── config.sh                # Генерация config.toml + tune
│   ├── docker.sh                # Docker: сборка, запуск, контейнер
│   ├── engine.sh                # Версии telemt
│   ├── traffic.sh               # Метрики, трафик, диагностика
│   ├── geoblock.sh              # Гео-блокировка
│   ├── upstream.sh              # Upstream-маршрутизация
│   ├── backup.sh                # Бэкапы, миграция
│   ├── nft.sh                   # NFT limiter + iOS фиксы
│   ├── selfmask.sh              # Selfmask (PQ nginx + Let's Encrypt)
│   ├── expert_catalog.sh        # Каталог параметров telemt
│   ├── expert_mode.sh           # Режим эксперта
│   ├── tui_main.sh              # Главное меню
│   ├── tui_proxy.sh             # Подменю: прокси
│   ├── tui_secrets.sh           # Подменю: секреты
│   ├── tui_links.sh             # Подменю: ссылки и QR
│   ├── tui_settings.sh          # Подменю: настройки
│   ├── tui_security.sh          # Подменю: безопасность
│   ├── tui_traffic.sh           # Подменю: трафик и метрики
│   ├── tui_engine.sh            # Подменю: движок
│   ├── tui_backup.sh            # Подменю: обновления и бэкапы
│   ├── tui_nft.sh               # Подменю: NFT limiter
│   ├── tui_selfmask.sh          # Подменю: selfmask
│   ├── tui_addons.sh            # Подменю: дополнения (PQ проверка)
│   └── install.sh               # Установщик + деинсталлятор
├── mtproxy/
│   └── config.toml              # Сгенерированный конфиг telemt
├── settings.conf                # Настройки MTProxyL
├── secrets.conf                 # Секреты пользователей
├── expert.conf                  # Expert override
├── tunings.conf                 # Быстрый тюнинг движка
├── nft-rules.conf               # Настройки NFT limiter
└── backups/                     # Бэкапы
```

---

<a id="requirements"></a>

## Требования

| Требование | Детали |
|-----------|--------|
| **ОС** | Ubuntu 20.04+, Debian 11+, CentOS, RHEL, Fedora, Rocky, AlmaLinux, Alpine |
| **Docker** | Устанавливается автоматически |
| **nftables** | Устанавливается автоматически |
| **Selfmask** | Пока только Debian/Ubuntu. Требуется домен с A-записью |
| **RAM** | 256 МБ минимум |
| **Доступ** | root |
| **Bash** | 4.2+ |

---

<a id="uninstall"></a>

## Удаление

```bash
mtproxyl uninstall
```

При удалении предлагается:
- Сохранить секреты
- Удалить selfmask и PQ nginx (если установлены)

Docker **не удаляется**. Сертификаты Let's Encrypt **не удаляются**.

---

<a id="thanks"></a>

## Благодарности

- **[MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)** — идея Smart режима NFT, TCP fingerprint, оптимизация sysctl

---

<a id="donate"></a>

## Поддержать автора

Если хотите поддержать проект и автора:
- [Cloudtips](https://pay.cloudtips.ru/p/ad2f7e4d)
- GRAM (TON) ```UQCcJR7546fnGX7jnJeFQdTUVMezVIvxutn074UezGOy_w8n```
- USDT (TRC20) ```TJKiqjDX7nLihV3ACJdJ9cgPwM169L2xmB```
- USDT (BER20) ```0xBf96ADb7c81eab25E56d7c40Bd414582E5B714A1```

---

## Лицензия

MIT

---

MTProxyL by LiafanX · [GitHub](https://github.com/Liafanx/MTProxyL)
