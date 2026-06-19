# MTProxyL

**MTProxyL** — менеджер Telegram MTProto прокси на базе движка **telemt** (Rust).

Один скрипт. Полный контроль.

## Установка

```bash
wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh
```

После установки запускается мастер настройки.
Для повторного входа в меню:

```bash
mtproxyl
```

## Что умеет

### Управление прокси
- Установка, запуск, остановка, перезапуск
- Docker-контейнер с telemt (Rust) — собирается автоматически
- Горячая перезагрузка конфига без обрыва соединений
- Автозапуск через systemd

### Управление пользователями
- Добавление / удаление / ротация секретов
- Лимиты: макс. соединений, IP, квота трафика, срок действия
- Клонирование, переименование
- QR-коды и ссылки для Telegram

### Движок Telemt
- Просмотр списка всех версий с GitHub
- Обновление до любой версии
- Откат к предыдущей
- Пересборка из исходников

### Режим эксперта
- Прямое редактирование любых параметров `config.toml`
- Параметры сохраняются и применяются поверх сгенерированного конфига
- Не теряются при обновлении или перезапуске

```bash
mtproxyl expert set censorship mask_relay_max_bytes 5242880
mtproxyl expert set server client_mss tspu
mtproxyl expert set general rst_on_close errors
mtproxyl expert list
mtproxyl expert clear all
mtproxyl expert edit    # открыть config.toml в nano
```

### NFT SYN Limiter
- Ограничение входящих SYN-пакетов по IP клиента через nftables
- Пресеты: жёсткий / средний / мягкий
- Дополнительные правила на другие порты
- Systemd-служба для автозапуска

### iOS фиксы
- **Вариант 1** — TCP keepalive через sysctl (настраиваемые значения)
- **Вариант 2** — MSS + redirect на отдельный порт для iOS-клиентов

### Безопасность
- Гео-блокировка по странам (ipset + iptables)
- Upstream-маршрутизация (SOCKS5 / SOCKS4 / direct)
- SNI-политика: mask или drop
- FakeTLS маскировка с выбором домена

### Бэкапы
- Обычные и зашифрованные (AES-256)
- Восстановление
- Миграция между серверами (export / import)
- Автоочистка старых бэкапов

### Мониторинг
- Трафик по пользователям (Prometheus)
- Активные соединения
- Диагностика
- Потоковые логи

## Модульная архитектура

Вместо одного скрипта на 8000+ строк — 14 библиотек:

```
/opt/mtproxyl/
├── mtproxyl.sh          # Главный скрипт
├── lib/
│   ├── colors.sh        # UI константы
│   ├── utils.sh         # Утилиты
│   ├── settings.sh      # Настройки
│   ├── secrets.sh       # Секреты
│   ├── config.sh        # Генерация config.toml + expert + tune
│   ├── docker.sh        # Docker
│   ├── engine.sh        # Версии telemt
│   ├── traffic.sh       # Метрики
│   ├── geoblock.sh      # Гео-блокировка
│   ├── upstream.sh      # Upstream-маршруты
│   ├── backup.sh        # Бэкапы
│   ├── nft.sh           # NFT limiter + iOS фиксы
│   ├── tui.sh           # Интерактивные меню
│   └── install.sh       # Установщик
├── mtproxy/
│   └── config.toml      # Конфиг telemt
├── settings.conf
├── secrets.conf
├── expert.conf          # Режим эксперта
└── backups/
```

## Основные команды

### Прокси
```bash
mtproxyl start              # Запустить
mtproxyl stop               # Остановить
mtproxyl restart             # Перезапустить
mtproxyl status              # Статус
mtproxyl status --json       # Статус в JSON
```

### Секреты
```bash
mtproxyl secret add alice           # Добавить
mtproxyl secret remove alice        # Удалить
mtproxyl secret list                # Список
mtproxyl secret rotate alice        # Обновить ключ
mtproxyl secret link alice          # Ссылка
mtproxyl secret qr alice            # QR-код
mtproxyl secret setlimits alice 100 5 10G 2026-12-31
```

### Движок
```bash
mtproxyl engine status       # Текущая версия
mtproxyl engine list         # Все доступные версии
mtproxyl engine update       # Обновить (интерактивно)
mtproxyl engine update 3.4.18  # Обновить до конкретной
mtproxyl engine rollback     # Откатить
mtproxyl engine rebuild      # Пересобрать
```

### Режим эксперта
```bash
mtproxyl expert set censorship mask_relay_max_bytes 0
mtproxyl expert set server client_mss tspu
mtproxyl expert list
mtproxyl expert clear client_mss
mtproxyl expert edit
```

### NFT лимитер
```bash
mtproxyl nft apply           # Применить правила
mtproxyl nft remove          # Удалить правила
mtproxyl nft preset hard     # Пресет (hard/medium/soft)
mtproxyl nft service         # Установить службу
mtproxyl nft drop            # Счётчик дропов
mtproxyl nft ios1            # iOS Fix v1
mtproxyl nft ios2            # iOS Fix v2
```

### Настройки
```bash
mtproxyl port 443
mtproxyl ip auto
mtproxyl domain cloudflare.com
mtproxyl mask-backend 127.0.0.1:8443
mtproxyl sni-policy mask
mtproxyl config              # Просмотр config.toml
```

### Безопасность
```bash
mtproxyl geoblock add ir     # Заблокировать страну
mtproxyl geoblock list       # Список
mtproxyl upstream list       # Upstream-маршруты
mtproxyl upstream add warp socks5 127.0.0.1:40000
```

### Мониторинг
```bash
mtproxyl traffic             # Трафик по пользователям
mtproxyl connections         # Активные соединения
mtproxyl metrics live 5      # Авто-обновление каждые 5с
mtproxyl logs                # Потоковые логи
mtproxyl health              # Диагностика
mtproxyl info                # Информация о сервере
```

### Бэкапы
```bash
mtproxyl backup              # Создать
mtproxyl backup --encrypt    # Зашифрованный
mtproxyl restore file.tar.gz # Восстановить
```

### Система
```bash
mtproxyl update              # Проверить обновления
mtproxyl uninstall           # Удалить
mtproxyl version             # Версия
mtproxyl help                # Справка
```

## Требования

| Требование | Детали |
|-----------|--------|
| **ОС** | Ubuntu, Debian, CentOS, RHEL, Fedora, Rocky, AlmaLinux, Alpine |
| **Docker** | Устанавливается автоматически |
| **RAM** | 256 МБ минимум |
| **Доступ** | Требуется root |
| **Bash** | 4.2+ |

## Отличия от MTProxyMax

| Возможность | MTProxyL | MTProxyMax |
|------------|:--------:|:----------:|
| Интерфейс на русском | ✅ | ❌ |
| Модульная архитектура | ✅ (14 библиотек) | ❌ (1 файл 8000+ строк) |
| Управление версиями Telemt | ✅ (list/update/rollback) | ❌ |
| Режим эксперта | ✅ (любые параметры config.toml) | ❌ |
| NFT SYN limiter | ✅ | ❌ |
| iOS фиксы (v1 + v2) | ✅ | ❌ |
| Telegram бот | ❌ (планируется) | ✅ |
| Slave/Replication | ❌ | ✅ |

## iOS фиксы

### Вариант 1 — TCP keepalive
Ускоряет обнаружение мёртвых сокетов через `sysctl`.
Значения настраиваются. Исходные значения сохраняются и восстанавливаются при откате.

### Вариант 2 — MSS + redirect
Создаёт отдельный порт для iOS (по умолчанию `4443`) с MSS=92 и прозрачным редиректом на основной порт.

> При использовании Варианта 2 убедитесь, что в конфиге нет `client_mss`.

iOS-пользователям нужно заменить только порт в ссылке.

## Удаление

Из меню: клавиша `u`

Или командой:
```bash
mtproxyl uninstall
```

## Лицензия

MIT

---

MTProxyL by LiafanX · [GitHub](https://github.com/Liafanx/MTProxyL)

1. Дать **LICENSE** файл (MIT)
2. Дать **чеклист тестирования перед первым релизом**
3. Или сразу начать дорабатывать конкретные части
