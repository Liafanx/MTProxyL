# MTProxyL

**MTProxyL** — менеджер Telegram MTProto прокси на базе движка **[telemt](https://github.com/telemt/telemt)** (Rust).

А также реанимация уже существующего прокси.

Установка в один клик. Полный контроль.

<p align="center">
  <img src="https://raw.githubusercontent.com/Liafanx/MTProxyL/main/mtproxyl.png" alt="MTProxyL" width="600">
</p>

---

## Навигация

- [Установка](#install)
- [Быстрый старт](#quickstart)
- [Режимы работы: Manager / Reanimator](#modes)
- [Выбор домена для FakeTLS](#pq-warning)
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
  - [Веб-панель](#cli-panel)
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
- [Веб-панель MTProxyL-Panel](#panel)
- [Устаревшие iOS фиксы](#ios-fixes)
- [Режим эксперта и супер эксперта — подробнее](#expert-details)
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

Переключение режима в любой момент — при переходе учитывается состояние
установки: из Reanimator в Manager, если своего telemt ещё нет, сразу
предлагается мастер установки; из Manager в Reanimator предлагается
остановить/удалить свой контейнер, чтобы он не держал порт цели.

Несколько установок на одном сервере не запрещены (например, контейнер
менеджера на 8443 и системный telemt на 443) — при занятом порте мастер
показывает, кто его слушает, и позволяет либо выбрать другой порт, либо
продолжить осознанно.

```bash
mtproxyl mode                # текущий режим
mtproxyl mode reanimator      # перейти в Reanimator (с подтверждением)
mtproxyl mode manager         # перейти в Manager (с подтверждением)
mtproxyl detect               # повторно найти цель (Reanimator)
mtproxyl edit-config          # открыть конфиг цели в редакторе (Reanimator)
mtproxyl install-telemt       # поставить/обновить оригинальный telemt (Reanimator)
mtproxyl uninstall-telemt     # удалить telemt: uninstall или purge (Reanimator)
```

Если на сервере вообще нет telemt — ни процесса, ни службы, ни бинарника —
чинить нечего, и MTProxyL предлагает поставить **оригинальный** telemt:
запускается официальный установщик проекта
([`telemt/telemt`](https://github.com/telemt/telemt), `install.sh`) как есть,
со своими вопросами про язык, порт и TLS-домен. Предложение появляется при
установке в режиме Reanimator, отдельным пунктом в главном меню и в меню
«Цель / режим». После установки цель обнаруживается заново, порт
синхронизируется с её конфигом и предлагается тюнинг таймаутов. Перед запуском
можно выбрать версию telemt — список релизов показывается по 10 на страницу,
по умолчанию ставится latest. Тем же установщиком telemt можно удалить
(`uninstall` — служба и бинарник, `purge` — вместе с конфигом и пользователем).

Установщик управляет только `telemt.service`: если цель — Docker-контейнер
сторонней панели или MTProxyMax, он её не обновляет, а ставит рядом отдельную
службу. При обновлении конфиг цели не перезаписывается целиком: меняются только
порт и `tls_domain`, а тюнинг, `[server.api]` и секреты остаются на месте.

Порт проверяется до запуска установщика. Отдельно разбирается случай, когда
порт держит собственный контейнер MTProxyL: он работает в сети host, поэтому
установщик telemt видит в `ss` процесс с именем `telemt`, считает порт своим и
продолжает установку — служба после этого не может занять порт. MTProxyL
предложит остановить или удалить контейнер либо указать в установщике другой
порт.

### Что доступно в режиме Reanimator

Меню и CLI адаптируются под режим: пункты, требующие владения движком/конфигом,
скрываются, а остальные работают против **цели**, а не собственного контейнера.

| Возможность | Как работает в Reanimator |
|-------------|---------------------------|
| Старт / стоп / рестарт | `systemctl` для `telemt.service`, `docker start/stop/restart` для контейнера, `mtproxymax` для MTProxyMax |
| Логи | `journalctl -u telemt` или `docker logs` цели |
| Ссылки на прокси | из API цели `GET /v1/users` (только IPv4-ссылки; секрет ee-ссылки содержит hex-домен, поэтому ссылки берутся как есть) |
| Трафик, соединения, пользователи | из API цели `/v1/users` (передано, соединения, уник. IP на пользователя) — работает без Prometheus-метрик, которые в telemt по умолчанию выключены |
| Метрики движка | из `metrics_listen`/`metrics_port` цели, если она их отдаёт; иначе MTProxyL предлагает включить их в конфиге цели, подобрав свободный порт |
| Диагностика | проверяет цель: способ управления, порт, конфиг, SNI-домен, API, метрики, применённые фиксы |
| Точечный тюнинг | `tune set` правит только указанный ключ в конфиге цели (с бэкапом), не перезаписывая файл целиком |
| Правка конфига | `edit-config` / отдельный пункт главного меню — открывает конфиг цели в `$EDITOR`/nano, делает бэкап и предлагает рестарт только если файл реально изменился |
| Гео-блокировка, NFT, Zapret2, iOS-фиксы, By-MEKO | как обычно — это host-level, владения конфигом не требуют |
| Установка telemt | если цели нет вовсе — запуск официального установщика `telemt/telemt` (`mtproxyl install-telemt`), затем повторный детект и тюнинг |
| Selfmask | заглушка поднимается на хосте, а `[censorship]` цели (`tls_domain`, `mask_host`, `mask_port`, `unknown_sni_action`) патчится точечно, с одним подтверждением и одним рестартом |

Скрыты (нужно владение движком/конфигом): секреты, настройки, движок Telemt,
режим эксперта, бэкапы/миграция, upstream-маршруты и SNI-политика. Пункты меню
нумеруются подряд для каждого режима, поэтому номера в Reanimator и Manager
различаются — ориентируйтесь на названия, а не на номера из скриншотов.

Перед первой правкой чужого конфига MTProxyL делает его резервную копию в
`/opt/mtproxyl/backups/` и печатает путь.

> API цели должен быть включён, иначе ссылки и статистика недоступны:
> ```toml
> [server.api]
> enabled = true
> listen = "127.0.0.1:9091"
> ```
>
> В режиме Manager MTProxyL пишет эту секцию в свой конфиг сам — порт
> спрашивается при установке и меняется в настройках, рядом с портом метрик.
> Указываем `listen` явно: по умолчанию telemt слушает `0.0.0.0:9091`, то есть
> без этой строки REST API движка был бы доступен из интернета.

---

<a id="pq-warning"></a>

## Выбор домена для FakeTLS

> **Если заглушку ставит MTProxyL** (**[Selfmask](#selfmask-details)**) — поддержка
> постквантового обмена ключами (X25519MLKEM768) обеспечивается самим backend'ом,
> и проверять домен не нужно. Это относится к обоим типам сертификата,
> включая самоподписанный.
>
> **Проверка нужна только для чужого домена**, который вы указываете в
> `tls_domain` вручную: если такой домен не поддерживает PQ, iOS-клиенты могут
> не подключиться (бесконечное «Соединение…»).
>
> **Как проверить:**
> - встроенная утилита: `mtproxyl pq-check ваш-домен.com`
> - меню: **Дополнения → проверить домен на PQ**
> - или бот: [@Sni_checker_bot](https://t.me/Sni_checker_bot)
>
> - 🟢 **сервер принимает X25519MLKEM768** — домен подходит
> - 🟡 **PQ нет, но Peer Temp Key не X25519** — можно использовать
> - 🔴 **PQ не поддерживается + Peer Temp Key = X25519** — **iOS не сможет подключиться**

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
- Ссылки и для Telegram

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
- Меню: `[7] → [2]` / CLI: `mtproxyl nft zapret2`

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
- X25519MLKEM768, 3 шаблона сайтов
- Два типа сертификата: **Let's Encrypt** (реальный домен с A-записью) либо
  **самоподписанный** (любой домен, в т.ч. несуществующий — A-запись и порт 80 не нужны)

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

mtproxyl superexpert status    # свой config.toml вместо генерируемого
mtproxyl superexpert on|off
mtproxyl superexpert edit
```

<a id="cli-nft"></a>

### NFT SYN Limiter

```bash
mtproxyl nft smart            # Включить Smart режим
mtproxyl nft preset smart     # Smart с параметрами по умолчанию
mtproxyl nft preset classic   # Classic: 1/second burst 1
mtproxyl nft apply            # Применить правила
mtproxyl nft remove           # Удалить правила
mtproxyl nft service          # Systemd-служба
mtproxyl nft drop             # Счётчик правил (live)
mtproxyl nft extra-add 8443   # Доп. правило
mtproxyl nft status           # Состояние (--json для машинного вывода)
```

**Параметры лимитера, iOS-фиксов и Zapret2** задаются без интерактивного меню —
25 значений с проверкой при записи. Так работает веб-панель:

```bash
mtproxyl nft settable         # Список параметров с текущими значениями (JSON)

mtproxyl nft set NFT_IOS_RATE 20/second
mtproxyl nft set NFT_OTHER_RATE 54/minute
mtproxyl nft set NFT_IOS_DETECT fingerprint   # fingerprint|ttl
mtproxyl nft set IOS_KA_TIME 45
mtproxyl nft set ZAPRET2_SPLIT_LEN 400

mtproxyl nft apply            # Переприменить правила (classic)
mtproxyl nft smart            # Переприменить правила (smart)
```

Сохранение параметра не меняет правила ядра — их нужно переприменить, как и
в меню.

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
mtproxyl selfmask status      # Статус (--json для машинного вывода)
mtproxyl selfmask setup       # Настроить через мастер (интерактивно)
mtproxyl selfmask verify      # Проверить
mtproxyl selfmask disable     # Отключить
mtproxyl selfmask menu        # Открыть меню
```

**Без мастера** — параметры задаются по отдельности и применяются одной
командой. Так работает веб-панель, и так же можно настраивать из скриптов:

```bash
mtproxyl selfmask settable    # Список параметров с текущими значениями (JSON)

mtproxyl selfmask set SELFMASK_DOMAIN example.com
mtproxyl selfmask set SELFMASK_CERT_MODE selfsigned      # letsencrypt|selfsigned
mtproxyl selfmask set SELFMASK_SITE_SOURCE mekorunner    # stub|filemanager|catrunner|mekorunner|URL
mtproxyl selfmask set SELFMASK_CERT_EMAIL admin@example.com
mtproxyl selfmask set SELFMASK_NGINX_BACKEND_PORT 8444
mtproxyl selfmask set SELFMASK_AUTO_RENEW true

mtproxyl selfmask apply       # Развернуть сайт и выпустить сертификат
```

Значения проверяются при записи: домен, email, порт и шаблон должны быть
корректными, иначе команда откажет.

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
mtproxyl geoblock list        # Список стран и состояние правил
mtproxyl geoblock reapply     # Переприменить после перезагрузки/смены порта
mtproxyl upstream list        # Upstream-маршруты
mtproxyl upstream add warp socks5 127.0.0.1:40000
```

Правила гео-блокировки живут в `iptables`/`ipset` и не переживают перезагрузку
сервера, поэтому `geoblock list` показывает не только список стран, но и
реальное состояние правил (и порт, на котором они висят). При смене порта
прокси правила переносятся автоматически.

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

<a id="cli-panel"></a>

### Веб-панель

```bash
mtproxyl panel status         # Состояние панели
mtproxyl panel install        # Установить / переустановить
mtproxyl panel restart        # Перезапустить
mtproxyl panel uninstall      # Удалить
```

---

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
mtproxyl edit-config          # открыть конфиг цели в $EDITOR/nano + предложить рестарт
mtproxyl install-telemt       # официальный установщик telemt: установка/обновление, выбор версии
mtproxyl uninstall-telemt     # официальный установщик telemt: uninstall / purge
```

---

<a id="zapret2-details"></a>

## Zapret2 MTProto fix — подробнее

> Новое в v1.2.0. Рекомендуемый метод обхода для серверов под активной блокировкой.
> Ручная установка без менеджера — [zapret2.md](zapret2.md).

### Как работает

| Шаг | Описание |
|-----|---------|
| 1 | В SYN+ACK объявляется окно `1400` вместо реального (десятки КБ), запоминается `ack0` |
| 2 | Клиент не может отправить ClientHello целиком: ядро Linux шлёт в объявленное окно примерно половину — около 700 байт |
| 3 | Этот первый data-пакет режется по `400`: первая часть (400) уходит как есть, вторая (300) — с **битой контрольной суммой**, третья оказывается пустой; оригинал дропается |
| 4 | Для DPI поток рвётся на испорченной части — собрать ClientHello он не может |
| 5 | Остаток ClientHello клиент досылает в зажатое окно `10`, скрипт считает прогресс `delta = th_ack − ack0` |
| 6 | При `delta ≥ 1400` соединение отпускается и помечается `fwmark` — дальше трафик идёт без вмешательства |

Подробный разбор с примером отладочного вывода — в [zapret2.md](zapret2.md).

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
mtproxyl                       # Меню → [7] → [2]
mtproxyl nft zapret2           # CLI: установить
mtproxyl nft zapret2-wscale    # Проверить wscale
```

### Дополнительные порты

Кроме порта прокси zapret2 можно навесить на любое число портов и диапазонов —
меню `[7] → [2] → Настройки → Доп. порты`, формат `8443,9000-9100`. Порт прокси
подставляется сам. В `--filter-tcp` уходит список через запятую, в NFT-правила —
анонимный set.

### Docker bridge

Если цель (режим Reanimator) живёт в Docker с bridge-сетью, трафик до неё идёт
через `forward`, а не через `prerouting`/`postrouting` хоста — правила
применяются в цепочке `forward`. Есть два варианта фильтрации:

| Стратегия | Правило | Когда |
|-----------|---------|-------|
| `simple` *(по умолчанию)* | только по портам, без `ip daddr/saddr` | надёжнее, watcher не нужен |
| `precise` | дополнительно сужается до IP контейнера | точнее; ставится watcher, т.к. IP контейнера меняется при пересоздании |

Выбор предлагается при установке и меняется позже в настройках zapret2.

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

Традиционное ограничение входящих SYN-пакетов. Стандартный вариант — 1/second burst 1, либо свои значения rate/burst.

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

Заглушку поднимает сам MTProxyL, поэтому поддержка PQ hybrid (X25519MLKEM768)
обеспечена backend'ом и проверять домен не нужно. Проверка на PQ нужна только
если вы используете **чужой** домен для FakeTLS — для этого есть меню
**Дополнения → проверка домена на PQ** или бот `@Sni_checker_bot`.

### Как работает

```
Telegram клиент → telemt :443 (MTProto)
Браузер / сканер → telemt :443 → mask → PQ nginx 127.0.0.1:8444 → ваш сайт
```

### Тип сертификата

| Режим | Когда выбирать | Требования |
|-------|----------------|------------|
| `letsencrypt` | Есть реальный домен, указывающий на этот сервер | A-запись + свободный порт 80 (ACME) |
| `selfsigned` | Домена нет или он несуществующий/чужой | Ничего: ни DNS, ни порта 80 |

В режиме `selfsigned` сертификат выписывается на 10 лет на любой указанный
домен, порт 80 не занимается (ACME и http→https redirect не нужны), а системный
nginx/панель на 80 порту не трогаются. Заглушка отдаётся только по SNI на
mask-backend, поэтому «снаружи» домен не открывается — это ожидаемое поведение.

### Что устанавливается

| Компонент | Путь | Описание |
|-----------|------|----------|
| PQ nginx | `/opt/mtproxyl-nginx/sbin/nginx` | nginx 1.28.3 + OpenSSL 3.5.7 (статический) |
| PQ OpenSSL | `/opt/mtproxyl-nginx/bin/openssl` | Для PQ-проверок |
| Конфиг | `/opt/mtproxyl-nginx/conf/nginx.conf` | Генерируется автоматически |
| Сайт | `/var/www/mtproxyl-selfmask/` | HTML-заглушка или шаблон |
| Сертификат (LE) | `/etc/letsencrypt/live/<домен>/` | Let's Encrypt (автопродление) |
| Сертификат (self) | `/opt/mtproxyl-nginx/selfsigned/<домен>/` | Самоподписанный, 10 лет |
| Служба | `mtproxyl-pq-nginx.service` | Systemd unit |

### Шаблоны сайтов

| Шаблон | Описание |
|--------|----------|
| Простая заглушка | «Сайт временно недоступен» |
| Файловый менеджер | Форма входа (всегда «неверные данные») |
| Cat Runner | Мини-игра: кот прыгает через кактусы |
| Свой URL | Любой `index.html` по ссылке |

---

<a id="panel"></a>

## Веб-панель MTProxyL-Panel

Опциональный веб-интерфейс ко всему, что умеет MTProxyL: пользователи, трафик,
переключение режимов, Selfmask, лимитер, Zapret2, блокировка стран, маршруты и
бэкапы. Интерфейс на русском, ставится одним бинарником.

Панель не заменяет MTProxyL, а работает поверх него — CLI и меню остаются
основным способом управления.

### Установка

Ставится **после** того, как прокси поднят: панели нужен работающий движок
с доступным API.

```bash
mtproxyl panel install
```

Либо через меню: **Дополнения → Веб-панель MTProxyL-Panel**.

Отдельно, без MTProxyL:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/MTProxyL/main/mtproxyl-panel/install.sh -o install-panel.sh
sh install-panel.sh install
```

После установки панель доступна на `http://<ваш-сервер>:8080`.

> Панель выпускается отдельно от MTProxyL — её релизы помечены тегом
> `mtproxyl-panel-vX.Y.Z`. Пока такого релиза нет, панель можно собрать прямо
> из ветки: `sh install-panel.sh install --from-source=dev`. При наличии Docker
> сборка идёт в нём и не оставляет тулчейн на сервере; иначе понадобятся
> Go 1.25+ и Node.js 20+. `mtproxyl panel install` предложит это сам.

### Управление

```bash
mtproxyl panel status      # состояние
mtproxyl panel restart     # перезапуск
mtproxyl panel uninstall   # удаление
```

### Права

Панель работает под собственным непривилегированным пользователем
`mtproxyl-panel`. Для команд, которым нужен root, установщик создаёт
`/etc/sudoers.d/mtproxyl-panel-mtproxyl` — список **конкретных** разрешённых
команд, а не право запускать `mtproxyl` целиком. При отключении интеграции или
удалении панели файл убирается.

### Ограничения

- Обновление движка telemt из панели недоступно: встроенный механизм рассчитан
  на systemd-сервис, а в режиме Manager движок работает в Docker. Используйте
  `mtproxyl engine`.
- Интерактивный мастер `selfmask setup` остаётся только в CLI: из панели
  параметры задаются по отдельности и применяются командой `selfmask apply`.
- Один администратор, без ролей и 2FA.
- Бэкапы, маршруты, экспертные параметры и супер эксперт доступны только в
  режиме Manager — в Reanimator они скрыты, так как требуют владения конфигом.
- Проверка ограничений сервера (censorcheck) в панель не перенесена: она
  выполняет сторонний скрипт из сети. Команда осталась в меню MTProxyL.

Подробности — [mtproxyl-panel/README.md](mtproxyl-panel/README.md).

---

<a id="ios-fixes"></a>

## Устаревшие iOS фиксы

> Доступны через меню `[7] NFT → [12] Устаревшие настройки`.
> При использовании **Zapret2 fix** или **Smart By-MEKO** эти фиксы не нужны.

### Вариант 1 — TCP keepalive

Ускоряет обнаружение мёртвых сокетов через `sysctl`.

### Вариант 2 — MSS + redirect

Отдельный порт для iOS с MSS=92. Только для Classic режима.

### Оптимизация системы By-MEKO

TCP keepalive 45s, BBR, расширенные очереди. Меню: `[7] → [11]`.

---

<a id="expert-details"></a>

## Режим эксперта — подробнее

Управление **любыми** параметрами telemt `config.toml` через каталог с валидацией.

Приоритет: `config.toml → tunings.conf → expert.conf`

Поддерживаемые секции: `general`, `general.modes`, `general.links`, `general.telemetry`, `network`, `server`, `server.listeners`, `server.conntrack_control`, `server.api`, `timeouts`, `censorship`, `censorship.tls_fetch`, `access`, `logging`

### Режим супер эксперта

Крайняя форма: конфиг движка вы ведёте сами, MTProxyL его не генерирует.

Включается в главном меню («Режим супер эксперта») или командой `mtproxyl superexpert on`.
При первом включении `/opt/mtproxyl/superexpert.toml` создаётся копией текущего рабочего
конфига — дальше правите файл вручную. Перед каждым запуском прокси он копируется на место
`config.toml`, поэтому изменения применяются обычным перезапуском.

Пока режим включён, менеджер в конфиг ничего не дописывает: «Управление секретами»,
«Настройки», «Режим эксперта», `tune set` и `expert set` блокируются — пользователи,
порт, домен и всё остальное задаются в вашем файле. Настройки хоста (NFT, Zapret2,
selfmask, гео-блокировка, бэкапы) работают как обычно, а порт из вашего конфига
подхватывается в настройки MTProxyL, чтобы правила и ссылки остались на нужном порту.

При выключении файл сохраняется: при следующем включении используется он же. Файл
попадает в бэкапы и в миграцию. В главном меню при включённом режиме выводится
«Режим супер эксперта включён».

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
│   ├── selfmask.sh              # Selfmask (PQ nginx + LE / самоподписанный cert)
│   ├── panel.sh                 # Установка и управление веб-панелью
│   ├── expert_catalog.sh        # Каталог параметров telemt
│   ├── expert_mode.sh           # Режим эксперта
│   ├── tui_main.sh              # Главное меню
│   ├── tui_proxy.sh             # Подменю: прокси
│   ├── tui_secrets.sh           # Подменю: секреты
│   ├── tui_links.sh             # Подменю: ссылки
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

Веб-панель — отдельный компонент в каталоге `mtproxyl-panel/` этого
репозитория: Go + React, собирается в один бинарник со встроенным фронтендом,
ставится своим установщиком. MTProxyL вызывает её установщик и показывает
состояние, но логику установки не дублирует.

---

<a id="requirements"></a>

## Требования

| Требование | Детали |
|-----------|--------|
| **ОС** | Ubuntu 20.04+, Debian 11+, CentOS, RHEL, Fedora, Rocky, AlmaLinux, Alpine |
| **Docker** | Устанавливается автоматически |
| **nftables** | Устанавливается автоматически |
| **curl** | Устанавливается автоматически если отсутствует |
| **Selfmask** | Только Debian/Ubuntu. Домен с A-записью нужен только для Let's Encrypt; для самоподписанного — не нужен |
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
