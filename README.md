# MTProxyL

**MTProxyL** — менеджер Telegram MTProto прокси на базе движка **[telemt](https://github.com/telemt/telemt)** (Rust).

Один скрипт. Полный контроль. Всё на русском.

<p align="center">
  <img src="https://raw.githubusercontent.com/Liafanx/MTProxyL/main/mtproxyl.png" alt="MTProxyL" width="600">
</p>

---

## Навигация

- [Установка](#install)
- [Быстрый старт](#quickstart)
- [Режимы работы: Manager / Reanimator](#modes)
- [⚠️ Важно: выбор домена для FakeTLS](#pq-warning)
- [Что умеет](#features)
- [Основные CLI команды](#cli)
  - [Прокси](#cli-proxy)
  - [Секреты (пользователи)](#cli-secrets)
  - [Настройки](#cli-settings)
  - [Движок Telemt](#cli-engine)
  - [Режим эксперта](#cli-expert)
  - [NFT SYN Limiter](#cli-nft)
  - [Zapret2 MTProto fix](#cli-zapret2)
  - [Selfmask](#cli-selfmask)
  - [PQ проверка](#cli-pqcheck)
  - [Безопасность](#cli-security)
  - [Мониторинг](#cli-monitoring)
  - [Бэкапы и обновления](#cli-backup)
  - [Система](#cli-system)
  - [Tune (быстрый тюнинг)](#cli-tune)
  - [Reanimator (режим/детект)](#cli-reanimator)
- [Zapret2 MTProto fix — подробнее](#zapret2-details)
- [NFT SYN Limiter — подробнее](#nft-details)
- [NFT Smart By-MEKO — подробнее](#nft-smart)
- [Selfmask — подробнее](#selfmask-details)
- [Устаревшие iOS фиксы](#ios-fixes)
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

> При первой установке скрипт первым предлагает **Zapret2 MTProto fix** (по умолчанию Y) — серверный обход через TCP-манипуляции. Если отказаться — предлагается **NFT Smart By-MEKO** — рекомендуемый режим с разделением iOS/Android.

---

<a id="quickstart"></a>

## Быстрый старт

1. Запустите установку:
   ```bash
   wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh
   ```

2. Следуйте мастеру настройки — выберите порт, домен, IP, режим обхода

3. Получите ссылку на прокси (выводится после установки) или:
   ```bash
   mtproxyl secret link
   ```

4. Откройте ссылку в Telegram — готово!

> Один порт для **всех** клиентов (iOS, Android, Desktop) — никаких дополнительных настроек.

---

<a id="modes"></a>

## Режимы работы: Manager / Reanimator

С версии 1.3.0 MTProxyL умеет работать в двух режимах — выбор происходит на первом шаге мастера установки (`mtproxyl install`):

- **Manager** *(по умолчанию, прежнее поведение)* — MTProxyL сам устанавливает движок telemt (образ из GHCR или сборка из исходников), сам генерирует `config.toml`, управляет секретами/upstream'ами/бэкапами и своим Docker-контейнером.
- **Reanimator** — вместо установки MTProxyL ищет уже работающую установку telemt на сервере (Docker-контейнер сторонней панели, MTProxyMax, голый процесс/systemd-юнит `telemt.service` или просто конфиг-файл) и применяет к ней тот же арсенал фиксов: NFT SYN limiter, Zapret2 MTProto fix, iOS-фиксы, оптимизацию By-MEKO и точечный тюнинг `config.toml` — не устанавливая ничего и не перезаписывая чужой конфиг целиком.

Переключение режима в любой момент:

```bash
mtproxyl mode                # текущий режим
mtproxyl mode reanimator      # перейти в Reanimator (с подтверждением)
mtproxyl mode manager         # перейти в Manager (с подтверждением)
mtproxyl detect               # повторно найти цель (Reanimator)
```

В режиме Reanimator недоступны команды, требующие владения движком/конфигом (`secret`, `upstream`, `port`, `domain`, `mask-backend`, `engine`, `expert`, `backup`/`restore`) — обо всём остальном (NFT, Zapret2, `tune set`, `status`, `traffic`, `logs`) MTProxyL заботится как обычно, но точечно и без установки.

---

<a id="pq-warning"></a>

## ⚠️ Важно: выбор домена для FakeTLS

> **Убедитесь что домен для FakeTLS поддерживает постквантовый гибридный алгоритм обмена ключами (X25519MLKEM768).**
>
> Если домен **не поддерживает** PQ — с высокой вероятностью после попытки подключения с iOS прилетит блокировка (бесконечное «Соединение…»).
>
> **Как проверить:**
> - встроенная утилита: `mtproxyl pq-check ваш-домен.com`
> - или бот: [@Sni_checker_bot](https://t.me/Sni_checker_bot)
>
> - 🟢 **сервер принимает X25519MLKEM768** — домен подходит
> - 🟡 **PQ нет, но Peer Temp Key не X25519** — можно использовать
> - 🔴 **PQ не поддерживается + Peer Temp Key = X25519** — **iOS не сможет подключиться**
>
> **Если у вас свой домен** — используйте **[Selfmask](#selfmask-details)**, который поднимает локальный PQ nginx с X25519MLKEM768.

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
- Клонирование, переименование, экспорт / импорт
- Ссылки и QR-коды для Telegram

### Движок Telemt
- Просмотр всех версий, обновление, откат, пересборка из исходников

### Режим эксперта
- Каталог **всех** параметров telemt `config.toml` с описаниями и валидацией
- Параметры применяются поверх сгенерированного конфига

### Zapret2 MTProto fix *(новое в v1.2.0, рекомендуется)*

Серверный обход через активное манипулирование TCP-пакетами:
- disorder + badsum + TCP window control
- iOS bypass по TCP fingerprint через `fwmark + ct mark`
- Автоподбор `win ACK` под конкретный сервер по формуле `wscale`
- Заменяет SYN limiter при включении
- Автозапуск через systemd, NFT таблица `ip MTProtoL`
- Меню: `[7] → [z]` / CLI: `mtproxyl nft zapret2`

### NFT SYN Limiter

**★ Smart By-MEKO** *(рекомендуется если Zapret2 не используется)*:
- Два метода определения iOS: **TCP fingerprint** и TTL+Length
- Раздельные лимиты для iOS и Android/Desktop
- Выбор действия: `icmp-host-unreachable` / `reject` / `drop`
- Один порт для всех клиентов

**Classic** — традиционный SYN limiter.

**Оптимизация By-MEKO** — TCP keepalive, BBR, расширенные очереди.

### Selfmask — маскировка под реальный сайт
- PQ nginx (nginx 1.28.3 + OpenSSL 3.5.7 статическая линковка)
- X25519MLKEM768, автоматический Let's Encrypt, 3 шаблона сайтов

### Безопасность
- Гео-блокировка, Upstream-маршрутизация, SNI-политика, FakeTLS

### Мониторинг и бэкапы
- Персистентный трафик, метрики, зашифрованные бэкапы, миграция

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
mtproxyl status --json        # Статус (JSON)
mtproxyl logs                 # Потоковые логи
```

<a id="cli-secrets"></a>

### Секреты (пользователи)

```bash
mtproxyl secret add alice              # Добавить пользователя
mtproxyl secret remove alice           # Удалить
mtproxyl secret list                   # Список с трафиком
mtproxyl secret rotate alice           # Новый ключ
mtproxyl secret enable alice           # Включить
mtproxyl secret disable alice          # Выключить
mtproxyl secret link alice             # Ссылка tg://
mtproxyl secret clone alice bob        # Клонировать
mtproxyl secret rename alice bob       # Переименовать
mtproxyl secret limits alice           # Лимиты
mtproxyl secret setlimits alice 100 5 10G 2026-12-31
```

<a id="cli-settings"></a>

### Настройки

```bash
mtproxyl port 443                      # Изменить порт
mtproxyl ip auto                       # Сбросить IP
mtproxyl domain cloudflare.com         # FakeTLS домен
mtproxyl mask-backend 127.0.0.1:8443   # Mask backend
mtproxyl sni-policy mask               # SNI-политика
mtproxyl config                        # Показать config.toml
```

<a id="cli-engine"></a>

### Движок Telemt

```bash
mtproxyl engine status                 # Текущая версия
mtproxyl engine list                   # Все версии
mtproxyl engine update                 # Обновить
mtproxyl engine update 3.4.24          # До конкретной версии
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
mtproxyl nft apply            # Применить правила
mtproxyl nft remove           # Удалить правила
mtproxyl nft service          # Systemd-служба
mtproxyl nft drop             # Счётчик правил (live)
mtproxyl nft extra-add 8443   # Доп. правило
```

<a id="cli-zapret2"></a>

### Zapret2 MTProto fix

```bash
mtproxyl nft zapret2          # Установить / переустановить
mtproxyl nft zapret2-stop     # Остановить
mtproxyl nft zapret2-rm       # Удалить
mtproxyl nft zapret2-wscale   # Проверить wscale / win ACK
```

<a id="cli-selfmask"></a>

### Selfmask

```bash
mtproxyl selfmask status      # Статус
mtproxyl selfmask setup       # Настроить / переустановить
mtproxyl selfmask verify      # Проверить
mtproxyl selfmask disable     # Отключить
mtproxyl selfmask menu        # Открыть меню
```

<a id="cli-pqcheck"></a>

### PQ проверка

```bash
mtproxyl pq-check                     # Текущий SNI-домен
mtproxyl pq-check cloudflare.com      # Любой домен
mtproxyl pq-check example.com:8443    # На нестандартном порту
```

<a id="cli-security"></a>

### Безопасность

```bash
mtproxyl geoblock add ir      # Заблокировать страну
mtproxyl geoblock remove ir   # Разблокировать
mtproxyl geoblock list        # Список
mtproxyl upstream list        # Upstream-маршруты
mtproxyl upstream add warp socks5 127.0.0.1:40000
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

<a id="cli-reanimator"></a>

### Reanimator (режим/детект)

```bash
mtproxyl mode                 # текущий режим (manager|reanimator)
mtproxyl mode manager         # переключиться в Manager
mtproxyl mode reanimator      # переключиться в Reanimator
mtproxyl detect               # (пере)обнаружить существующую установку telemt
```

---

<a id="zapret2-details"></a>

## Zapret2 MTProto fix — подробнее

> Новое в v1.2.0. Рекомендуемый метод обхода для серверов под активной блокировкой.

### Как работает

| Шаг | Описание |
|-----|---------|
| 1 | SYN+ACK с `window=1400` → клиент дробит ClientHello |
| 2 | Пустые ACK с `window=10` пока клиент не отправил payload |
| 3 | Первый data-пакет режется на 3 части: 1-я нормально, 3-я со смещением, 2-я с **битой контрольной суммой** |
| 4 | Неполучается собрать ClientHello → пропускает |
| 5 | Клиент ретрансмитирует среднюю часть → соединение установлено |
| 6 | Дальнейший трафик без вмешательства |

### iOS bypass

iOS-клиенты определяются по TCP SYN fingerprint и маркируются через `fwmark` — проходят без манипуляций с окном.

### Проверка wscale

Реальное TCP окно = `win_ACK × 2^wscale`. Должно быть **< 1400 байт**. Скрипт проверяет это автоматически:

| wscale | 2^wscale | win ACK | Реальное окно |
|--------|----------|---------|---------------|
| 7 | 128 | 10 | 1280 байт ✓ |
| 9 | 512 | 2 | 1024 байт ✓ |
| 11 | 2048 | — | невозможно ✗ |

При `wscale ≥ 11` (буфер 64 МБ+) скрипт выведет инструкцию по уменьшению `net.core.rmem_max`.

### Управление

```bash
mtproxyl                       # Меню → [7] → [z]
mtproxyl nft zapret2           # CLI: установить
mtproxyl nft zapret2-wscale    # Проверить wscale
```

### NFT таблица

```
table ip MTProtoL {
    chain predefrag   # output -401: пропуск помеченных + notrack
    chain output      # route mangle: ct mark set
    chain postrouting # srcnat+1: ct mark accept + queue
    chain prerouting  # mangle: ct mark accept + queue
}
```

---

<a id="nft-details"></a>

## NFT SYN Limiter — подробнее

> Используйте если **Zapret2 fix** не подходит или недоступен.

MTProxyL поддерживает два режима: **Smart By-MEKO** и **Classic**.

### Classic режим

Традиционное ограничение входящих SYN-пакетов. Доступен пресет: жёсткий (1/s burst 1) или свой вариант.

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
| iOS Limit | отключён | iOS пропускаются без ограничений |
| Other Rate | 54/minute | Лимит SYN для Android/Desktop |
| Other Burst | 1 | Burst для Other |
| Other Action | icmp-host-unreachable | Действие при превышении |
| iOS Detect | fingerprint | Метод определения iOS |

---

<a id="selfmask-details"></a>

## Selfmask — маскировка под реальный сайт

Selfmask превращает прокси-сервер в полноценный HTTPS-сайт на собственном домене.

### Как работает

```
Telegram клиент → telemt :443 (MTProto)
Браузер / сканер → telemt :443 → mask → PQ nginx 127.0.0.1:8444 → ваш сайт
```

### Что устанавливается

| Компонент | Путь | Описание |
|-----------|------|----------|
| PQ nginx | `/opt/mtproxyl-nginx/sbin/nginx` | nginx 1.28.3 + OpenSSL 3.5.7 (статический) |
| PQ OpenSSL | `/opt/mtproxyl-nginx/bin/openssl` | Для PQ-проверок |
| Конфиг | `/opt/mtproxyl-nginx/conf/nginx.conf` | Генерируется автоматически |
| Сайт | `/var/www/mtproxyl-selfmask/` | HTML-заглушка или шаблон |
| Сертификат | `/etc/letsencrypt/live/<домен>/` | Let's Encrypt (автопродление) |
| Служба | `mtproxyl-pq-nginx.service` | Systemd unit |

### Шаблоны сайтов

| Шаблон | Описание |
|--------|----------|
| Простая заглушка | «Сайт временно недоступен» |
| Файловый менеджер | Форма входа (всегда «неверные данные») |
| Cat Runner | Мини-игра: кот прыгает через кактусы |
| Свой URL | Любой `index.html` по ссылке |

---

<a id="ios-fixes"></a>

## Устаревшие iOS фиксы

> Доступны через меню `[7] NFT → [o] Устаревшие настройки`.
> При использовании **Zapret2 fix** или **Smart By-MEKO** эти фиксы не нужны.

### Вариант 1 — TCP keepalive

Ускоряет обнаружение мёртвых сокетов через `sysctl`.

### Вариант 2 — MSS + redirect

Отдельный порт для iOS с MSS=92. Только для Classic режима.

### Оптимизация системы By-MEKO

TCP keepalive 45s, BBR, расширенные очереди. Меню: `[7] → [m]`.

---

<a id="expert-details"></a>

## Режим эксперта — подробнее

Управление **любыми** параметрами telemt `config.toml` через каталог с валидацией.

Приоритет: `config.toml → tunings.conf → expert.conf`

Поддерживаемые секции: `general`, `general.modes`, `general.links`, `general.telemetry`, `network`, `server`, `server.listeners`, `server.conntrack_control`, `server.api`, `timeouts`, `censorship`, `censorship.tls_fetch`, `access`, `logging`

---

<a id="architecture"></a>

## Модульная архитектура

```
/opt/mtproxyl/
├── mtproxyl.sh                  # Главный скрипт + CLI dispatcher
├── lib/
│   ├── colors.sh                # UI: цвета, символы
│   ├── utils.sh                 # Утилиты, валидация, CLI-обработчики
│   ├── settings.sh              # Настройки
│   ├── detect.sh                # Reanimator: детект чужого telemt + точечный тюнинг
│   ├── secrets.sh               # Секреты пользователей
│   ├── config.sh                # Генерация config.toml
│   ├── docker.sh                # Docker
│   ├── engine.sh                # Версии telemt
│   ├── traffic.sh               # Метрики, трафик
│   ├── geoblock.sh              # Гео-блокировка
│   ├── upstream.sh              # Upstream
│   ├── backup.sh                # Бэкапы
│   ├── nft.sh                   # NFT limiter + Zapret2 fix + iOS фиксы
│   ├── selfmask.sh              # Selfmask (PQ nginx + Let's Encrypt)
│   ├── expert_catalog.sh        # Каталог параметров telemt
│   ├── expert_mode.sh           # Режим эксперта
│   ├── tui_main.sh              # Главное меню
│   ├── tui_proxy.sh             # Подменю: прокси
│   ├── tui_secrets.sh           # Подменю: секреты
│   ├── tui_links.sh             # Подменю: ссылки и QR
│   ├── tui_settings.sh          # Подменю: настройки
│   ├── tui_security.sh          # Подменю: безопасность
│   ├── tui_traffic.sh           # Подменю: трафик
│   ├── tui_engine.sh            # Подменю: движок
│   ├── tui_backup.sh            # Подменю: обновления и бэкапы
│   ├── tui_nft.sh               # Подменю: NFT + Zapret2
│   ├── tui_selfmask.sh          # Подменю: selfmask
│   ├── tui_addons.sh            # Подменю: дополнения
│   ├── tui_detect.sh            # Подменю: цель / режим (Reanimator)
│   └── install.sh               # Установщик + деинсталлятор
├── mtproxy/config.toml          # Конфиг telemt
├── settings.conf                # Настройки MTProxyL
├── secrets.conf                 # Секреты
├── expert.conf                  # Expert override
├── tunings.conf                 # Быстрый тюнинг
├── nft-rules.conf               # NFT настройки (включая Zapret2)
└── backups/
```

---

<a id="requirements"></a>

## Требования

| Требование | Детали |
|-----------|--------|
| **ОС** | Ubuntu 20.04+, Debian 11+, CentOS, RHEL, Fedora, Rocky, AlmaLinux, Alpine |
| **Docker** | Устанавливается автоматически |
| **nftables** | Устанавливается автоматически |
| **curl** | Устанавливается автоматически если отсутствует |
| **Selfmask** | Только Debian/Ubuntu. Требуется домен с A-записью |
| **RAM** | 256 МБ минимум |
| **Доступ** | root |
| **Bash** | 4.2+ |

---

<a id="uninstall"></a>

## Удаление

```bash
mtproxyl uninstall
```

При удалении предлагается сохранить секреты и удалить selfmask / PQ nginx.  
Docker, сертификаты Let's Encrypt и Zapret2 NFT-таблица очищаются автоматически.

---

<a id="thanks"></a>

## Благодарности

- **[MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)** — идея Smart режима NFT, TCP fingerprint, оптимизация sysctl

---

<a id="donate"></a>

## Поддержать автора

- [Cloudtips](https://pay.cloudtips.ru/p/ad2f7e4d)
- GRAM (TON) ```UQCcJR7546fnGX7jnJeFQdTUVMezVIvxutn074UezGOy_w8n```
- USDT (TRC20) ```TJKiqjDX7nLihV3ACJdJ9cgPwM169L2xmB```
- USDT (BER20) ```0xBf96ADb7c81eab25E56d7c40Bd414582E5B714A1```

---

## Лицензия

MIT

---

MTProxyL by LiafanX · [GitHub](https://github.com/Liafanx/MTProxyL)
