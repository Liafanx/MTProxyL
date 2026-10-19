# API управления MTProxyL

`mtproxyl-api` — HTTP API для управления MTProxyL из других проектов: ботов
продажи доступа, личных кабинетов, CRM, скриптов мониторинга. Через него
создают, меняют и удаляют пользователей прокси, задают им все лимиты (число
соединений, уникальных IP, квоту трафика, срок действия, скорость, рекламную
метку), получают ссылки и состояние прокси.

- По умолчанию **выключен**. Включается одной командой на сервере.
- Работает **без веб-панели** — это отдельная служба.
- Работает в обоих режимах MTProxyL: **Manager** и **Reanimator**.
- **Совместим с API telemt**: те же пути, поля, форматы ответов и коды
  ошибок (`UserInfo`, `CreateUserResponse`, JSON Merge Patch, `revision` и
  `If-Match`, `user_exists`). Клиент, написанный под API telemt, работает с
  `mtproxyl-api` без правок — меняются только адрес и ключ.

> Почему не API самого telemt? В режиме Manager конфиг движка собирает
> MTProxyL, и пользователи, созданные через API движка, пропадут при
> следующей пересборке (а в Docker запись и вовсе запрещена). `mtproxyl-api`
> работает через MTProxyL, поэтому изменения сохраняются, попадают в
> статистику, бэкапы, экспорт и в WEB Proxy.

## Содержание

- [Включение](#включение)
- [Настройка доступа](#настройка-доступа)
- [Ключ](#ключ)
- [Формат запросов и ответов](#формат-запросов-и-ответов)
- [Объект пользователя](#объект-пользователя)
- [Методы](#методы)
- [Коды ошибок](#коды-ошибок)
- [Примеры](#примеры)
- [Безопасность](#безопасность)
- [Устройство и диагностика](#устройство-и-диагностика)

## Включение

```bash
mtproxyl api on
```

Команда:

1. скачивает `mtproxyl-api` из последнего релиза панели (`/usr/local/bin/mtproxyl-api`);
2. создаёт системного пользователя `mtproxyl-api` и правила sudo только для
   нужных команд (`/etc/sudoers.d/mtproxyl-api`);
3. создаёт ключ и **один раз** выводит его — сохраните;
4. запускает службу `mtproxyl-api.service`.

По умолчанию API слушает только `127.0.0.1:9190` — доступен с самого
сервера. Чтобы обращаться снаружи, задайте адрес (см. ниже).

То же из меню: **Дополнения → API управления**, из панели: **API управления**.
При установке аргументами: `--api yes`, `--api-listen 0.0.0.0:9190`,
`--api-allow 203.0.113.10`.

Остальные команды:

| Команда | Что делает |
| --- | --- |
| `mtproxyl api status [--json]` | Состояние, адрес, версия |
| `mtproxyl api off` | Выключить службу (ключ сохраняется) |
| `mtproxyl api key` | Выдать новый ключ, прежний сразу перестаёт работать |
| `mtproxyl api set API_LISTEN 0.0.0.0:9190` | Где слушать |
| `mtproxyl api set API_ALLOW 203.0.113.10,10.0.0.0/8` | С каких адресов пускать (`-` — с любых) |
| `mtproxyl api set API_TLS selfmask` | HTTPS на сертификате Selfmask (`off` — без HTTPS) |
| `mtproxyl api update` | Обновить бинарник до последнего релиза |
| `mtproxyl api uninstall` | Удалить службу, ключ, правила sudo и пользователя |

## Настройка доступа

| Параметр | По умолчанию | Значение |
| --- | --- | --- |
| `API_LISTEN` | `127.0.0.1:9190` | Адрес и порт. `0.0.0.0:<порт>` — снаружи |
| `API_ALLOW` | пусто | IP и подсети через запятую. Остальные получат `403` ещё до проверки ключа |
| `API_TLS` | `off` | `selfmask` — HTTPS на сертификате домена Selfmask; сертификат обновляется вместе с продлением |

Если включён ufw, порт открывается автоматически. Облачный firewall
провайдера настройте сами.

Рекомендуемая схема для доступа снаружи:

```bash
mtproxyl api set API_LISTEN 0.0.0.0:9190
mtproxyl api set API_TLS selfmask
mtproxyl api set API_ALLOW 203.0.113.10   # адрес вашего сервера-интегратора
```

## Ключ

Ключ — 64 шестнадцатеричных символа. На сервере хранится только его SHA-256
(`/etc/mtproxyl-api/key.sha256`), поэтому показать ключ повторно нельзя —
только выдать новый (`mtproxyl api key`).

Передаётся в заголовке `Authorization` в любом из двух видов:

```
Authorization: Bearer 3f1c…a9
Authorization: 3f1c…a9
```

После 10 неверных ключей с одного адреса за минуту API отвечает `429` до
конца минуты; каждый неверный ключ отвечает с задержкой.

## Формат запросов и ответов

Формат — как у [API telemt](https://github.com/telemt/telemt/blob/main/docs/API.md).

- Тело запросов и ответов — JSON, UTF-8. `Content-Type` не обязателен.
- Тело запроса — не больше 64 КБ. Незнакомые поля пропускаются, как у
  telemt: можно прислать объект пользователя из `GET` целиком.
- Успех:

```json
{ "ok": true, "data": { … }, "revision": "43fc4932…" }
```

`revision` — отпечаток настроек пользователей (SHA-256, hex); есть в ответах
методов `/v1/users…`. Его можно передать в заголовке `If-Match` при изменении:
если с тех пор пользователей кто-то поменял, ответ — `409 revision_conflict`
и ничего не меняется. Без `If-Match` проверки нет.

- Ошибка:

```json
{ "ok": false, "error": { "code": "not_found", "message": "Секрет 'bob' не найден" }, "request_id": 7 }
```

`message` — текст для человека (на русском), `code` — для программы.

Имя пользователя (`username`): латиница, цифры, `_` и `-`, первая — буква
или цифра, до 32 символов. Это строже, чем у telemt (там ещё `.` и до 64
символов): такие имена принимает MTProxyL.

Запросы, меняющие состояние, выполняются по одному: параллельные ждут
очереди. Одна операция обычно занимает 1–3 секунды (MTProxyL пересобирает
конфиг движка и перечитывает его без разрыва соединений).

## Объект пользователя

`UserInfo` — как у telemt, плюс несколько полей MTProxyL в конце.

```json
{
  "username": "alice",
  "enabled": true,
  "in_runtime": true,
  "user_ad_tag": null,
  "max_tcp_conns": 8,
  "expiration_rfc3339": "2027-01-31T23:59:59+00:00",
  "data_quota_bytes": 10737418240,
  "rate_limit_up_bps": null,
  "rate_limit_down_bps": 20000000,
  "max_unique_ips": 3,
  "current_connections": 2,
  "active_unique_ips": 1,
  "active_unique_ips_list": ["198.51.100.7"],
  "recent_unique_ips": 1,
  "recent_unique_ips_list": ["198.51.100.7"],
  "total_octets": 53477376,
  "links": {
    "classic": [],
    "secure": [],
    "tls": ["tg://proxy?server=proxy.example.com&port=443&secret=ee5ec9…"],
    "tls_domains": [],
    "web": ["tg://webproxy?server=web.example.com&secret=dd5ec9…"]
  },
  "secret": "5ec993f420bc4f580ebc8b7d8dc1e43d",
  "notes": "",
  "created": 1791715149,
  "traffic": { "in_bytes": 1048576, "out_bytes": 52428800, "total_bytes": 53477376 }
}
```

| Поле | Тип | Описание |
| --- | --- | --- |
| `username` | string | Имя (метка) пользователя |
| `enabled` | bool | Выключенный пользователь не может подключиться, но не удаляется |
| `in_runtime` | bool | Пользователь уже есть в работающем движке |
| `user_ad_tag` | string \| null | Своя рекламная метка (32 hex от @MTProxybot). `null` — общая |
| `max_tcp_conns` | int \| null | Одновременных TCP-соединений. `null` — без ограничения |
| `expiration_rfc3339` | string \| null | Срок действия, RFC3339 в UTC (`…+00:00`, как у telemt). `null` — бессрочно |
| `data_quota_bytes` | int \| null | Квота трафика в байтах. `null` — без ограничения |
| `rate_limit_up_bps` | int \| null | Скорость от клиента, бит/с. `null` — без ограничения. Нужен telemt 3.4.1+ |
| `rate_limit_down_bps` | int \| null | Скорость к клиенту, бит/с. `null` — без ограничения |
| `max_unique_ips` | int \| null | Уникальных IP. `null` — без ограничения |
| `current_connections` | int | Подключений сейчас (из движка) |
| `active_unique_ips`, `active_unique_ips_list` | int, string[] | Активные IP (из движка) |
| `recent_unique_ips`, `recent_unique_ips_list` | int, string[] | IP за недавнее окно движка |
| `total_octets` | int | Трафик по счётчику движка, байты |
| `links` | object | Ссылки по видам, как у telemt: `classic`, `secure` (dd), `tls` (ee), `tls_domains` (`{domain, link}` для дополнительных доменов), плюс `web` — ссылки `tg://webproxy`, если включён WEB Proxy |
| `secret` | string | *MTProxyL.* Секрет, 32 hex |
| `notes` | string | *MTProxyL.* Заметка (только чтение) |
| `created` | int | *MTProxyL.* Время создания, Unix-секунды (`0` у пользователей цели в Reanimator) |
| `traffic` | object | *MTProxyL.* Накопленный трафик, байты: от клиента, к клиенту, всего. В отличие от `total_octets` переживает перезапуски движка |

Если API движка не отвечает, живые поля (`current_connections`, списки IP)
нулевые, `total_octets` берётся из накопленного трафика.

Скорость в бит/с: 10 Мбит/с = `10000000`, 512 кбит/с = `512000`. Максимум —
100 Гбит/с.

## Методы

| Метод | Путь | Ответ `data` |
| --- | --- | --- |
| `GET` | `/v1/health` | `{status, read_only, api_version}` |
| `GET` | `/v1/status` | Состояние прокси (MTProxyL) |
| `POST` | `/v1/proxy/restart` | `{restarted}` (MTProxyL) |
| `GET` | `/v1/users` | `UserInfo[]`, по имени |
| `POST` | `/v1/users` | `201`, `{user: UserInfo, secret}` |
| `GET` | `/v1/users/{username}` | `UserInfo` |
| `PATCH` | `/v1/users/{username}` | `UserInfo` |
| `DELETE` | `/v1/users/{username}` | `{username, in_runtime}` |
| `POST` | `/v1/users/{username}/enable` | `UserInfo` |
| `POST` | `/v1/users/{username}/disable` | `UserInfo` |
| `POST` | `/v1/users/{username}/rotate-secret` | `{user: UserInfo, secret}` |
| `POST` | `/v1/users/{username}/reset-quota` | `{username, used_bytes, last_reset_epoch_secs}` |
| `POST` | `/v1/users/{username}/reset-traffic` | `{username, traffic}` (MTProxyL) |
| `GET` | `/v1/users/{username}/links` | `{username, links}` (MTProxyL) |

### `GET /v1/health`

Ничего не делает, кроме проверки ключа. Удобно для проверки интеграции.

```json
{ "ok": true, "data": { "status": "ok", "read_only": false, "api_version": "1.3.1" } }
```

### `GET /v1/status`

Состояние прокси — тот же JSON, что `mtproxyl status --json`:

```json
{
  "ok": true,
  "data": {
    "version": "1.7.1", "mode": "manager", "status": "running",
    "port": 443, "domain": "proxy.example.com", "uptime": 86400,
    "connections": 120, "unique_ips": 87,
    "traffic_in": 1234567, "traffic_out": 98765432, "traffic_total": 99999999,
    "web": { "enabled": true, "domain": "web.example.com", "layout": "shared",
             "carrier": "websocket", "proxy_mode": "combined" }
  }
}
```

### `POST /v1/proxy/restart`

Перезапускает движок (Manager) или цель (Reanimator). Активные соединения
рвутся. Ответ: `{"ok":true,"data":{"restarted":true}}`.

### `GET /v1/users`

Массив [`UserInfo`](#объект-пользователя), отсортированный по имени, со
ссылками и живыми данными движка.

### `POST /v1/users`

Создаёт пользователя и сразу применяет все переданные лимиты. Обязательно
только `username`.

```json
{
  "username": "alice",
  "secret": "5ec993f420bc4f580ebc8b7d8dc1e43d",
  "enabled": true,
  "max_tcp_conns": 8,
  "max_unique_ips": 3,
  "data_quota_bytes": 10737418240,
  "expiration_rfc3339": "2027-01-31T23:59:59Z",
  "user_ad_tag": "0123456789abcdef0123456789abcdef",
  "rate_limit_up_bps": 5000000,
  "rate_limit_down_bps": 20000000
}
```

- `secret` — необязательно: без него сгенерируется.
- `expiration_rfc3339` — RFC3339 с любым смещением (`Z`, `+03:00`) или
  `ГГГГ-ММ-ДД` (до конца этого дня по UTC). В ответе срок всегда в UTC с `+00:00`.
- `enabled: false` — создать сразу выключенным.

Ответ — `201`, как `CreateUserResponse` у telemt:

```json
{ "ok": true, "data": { "user": { "username": "alice", … }, "secret": "5ec993f4…" }, "revision": "…" }
```

Если лимит не прошёл проверку, пользователь не остаётся наполовину созданным:
он удаляется, а в ответе — ошибка. Имя занято — `409 user_exists`.

### `GET /v1/users/{username}`

`UserInfo`. `404`, если такого нет.

### `PATCH /v1/users/{username}`

JSON Merge Patch, как у telemt: поле не передано — не меняется, `null` —
снять ограничение, значение — установить.

```json
{ "data_quota_bytes": 21474836480, "expiration_rfc3339": "2027-02-28T20:59:59+00:00", "max_tcp_conns": null }
```

- `null` снимает ограничение: для лимитов, скорости, срока и метки. `0` и
  `""` тоже снимают. `"enabled": null` — включить, как у telemt.
- `secret` — поставить этот секрет (32 hex); старые ссылки перестанут
  работать. Совпадающий с текущим ничего не меняет.
- Имя пользователя берётся из адреса (`/v1/users/alice`). `username` в теле —
  расширение MTProxyL: *новое* имя, то есть переименование. Пустая строка,
  `null` или текущее имя игнорируются, поэтому объект из `GET` можно
  присылать целиком. Переименование выполняется последним: если другая правка
  не прошла, имя остаётся прежним.
- Поля только для чтения (`in_runtime`, `links`, `current_connections`,
  `traffic` и т.п.) игнорируются.

Продлить срок пользователю `px-462031623-7`:

```bash
curl -X PATCH -H "Authorization: Bearer $KEY" \
  https://proxy.example.com:9190/v1/users/px-462031623-7 \
  -d '{"expiration_rfc3339":"2027-03-01T00:00:00+00:00"}'
```

Ответ — `UserInfo` (уже под новым именем, если меняли).

### `DELETE /v1/users/{username}`

```json
{ "ok": true, "data": { "username": "alice", "in_runtime": false }, "revision": "…" }
```

В Manager последнего пользователя удалить нельзя — `409 last_user_forbidden`:
движок без пользователей не запускается.

### `POST /v1/users/{username}/enable`, `/disable`

Включает или выключает пользователя. Ответ — `UserInfo`.

### `POST /v1/users/{username}/rotate-secret`

Новый секрет. Тело необязательно: `{"secret":"<32 hex>"}` ставит заданный,
без тела — случайный. Старые ссылки сразу перестают работать. Ответ — как у
создания: `{user, secret}`.

### `POST /v1/users/{username}/reset-quota`

Обнуляет израсходованную квоту: её считает сам движок, и сброс идёт через
его API. Нужен включённый API движка (по умолчанию включён). Накопленный
MTProxyL трафик (`traffic`) не меняется.

```json
{ "ok": true, "data": { "username": "alice", "used_bytes": 0, "last_reset_epoch_secs": 1791800000 } }
```

Типичный сценарий продления подписки — сбросить квоту и сдвинуть срок:

```bash
curl -X POST  …/v1/users/alice/reset-quota
curl -X PATCH …/v1/users/alice -d '{"expiration_rfc3339":"2027-03-31"}'
```

### `POST /v1/users/{username}/reset-traffic`

*MTProxyL.* Сбрасывает накопленную статистику пользователя: трафик и историю
IP. Квоту движка не трогает — для неё `reset-quota`.

### `GET /v1/users/{username}/links`

*MTProxyL.* Только ссылки, в том же виде, что `links` в `UserInfo`.

```json
{ "ok": true, "data": { "username": "alice", "links": { "classic": [], "secure": [], "tls": ["tg://proxy?…"], "tls_domains": [], "web": ["tg://webproxy?…"] } } }
```

## Коды ошибок

| HTTP | `code` | Когда |
| --- | --- | --- |
| `400` | `bad_request` | Неверное имя, неверный формат значения |
| `401` | `unauthorized` | Нет ключа или ключ неверный |
| `403` | `forbidden` | Адрес не входит в `API_ALLOW` |
| `404` | `not_found` | Пользователь не найден |
| `409` | `user_exists` | Пользователь с таким именем уже есть |
| `409` | `last_user_forbidden` | Нельзя удалить последнего пользователя |
| `409` | `revision_conflict` | `If-Match` не совпал с текущей ревизией |
| `422` | `rejected` | MTProxyL отказал: например, значение вне допустимого, выключен API движка |
| `429` | `too_many_attempts` | Слишком много неверных ключей с этого адреса за минуту |
| `504` | `timeout` | Команда MTProxyL не уложилась в 5 минут |

## Примеры

### curl

```bash
API=https://proxy.example.com:9190
KEY=3f1c…a9

# Создать пользователя на месяц с квотой 50 ГБ и скоростью 20 Мбит/с
curl -s -X POST "$API/v1/users" -H "Authorization: Bearer $KEY" \
  -d '{"username":"order1042","data_quota_bytes":53687091200,
       "expiration_rfc3339":"2026-11-11","rate_limit_down_bps":20000000}' \
  | jq -r '.data.user.links.tls[0]'

# Сколько потратил
curl -s "$API/v1/users/order1042" -H "Authorization: Bearer $KEY" | jq '.data.traffic'

# Заблокировать за неоплату и включить обратно
curl -s -X POST "$API/v1/users/order1042/disable" -H "Authorization: Bearer $KEY"
curl -s -X POST "$API/v1/users/order1042/enable"  -H "Authorization: Bearer $KEY"

# Удалить
curl -s -X DELETE "$API/v1/users/order1042" -H "Authorization: Bearer $KEY"
```

### Python

```python
import requests

API = "https://proxy.example.com:9190"
S = requests.Session()
S.headers["Authorization"] = "Bearer 3f1c…a9"

def call(method, path, **kw):
    r = S.request(method, API + path, timeout=60, **kw)
    body = r.json()
    if not body["ok"]:
        raise RuntimeError(f'{r.status_code} {body["error"]["code"]}: {body["error"]["message"]}')
    return body["data"]

created = call("POST", "/v1/users", json={
    "username": "tg_123456789",
    "max_unique_ips": 3,
    "data_quota_bytes": 50 * 1024**3,
    "expiration_rfc3339": "2026-11-11",
})
print(created["user"]["links"]["tls"], created["secret"])

call("PATCH", "/v1/users/tg_123456789", json={"rate_limit_down_bps": 10_000_000})
```

### Node.js

```js
const API = 'https://proxy.example.com:9190';
const KEY = '3f1c…a9';

async function call(method, path, body) {
  const res = await fetch(API + path, {
    method,
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  if (!json.ok) throw new Error(`${res.status} ${json.error.code}: ${json.error.message}`);
  return json.data;
}

const users = await call('GET', '/v1/users');
const expired = users.filter((u) => u.expiration_rfc3339 && new Date(u.expiration_rfc3339) < new Date());
for (const u of expired) await call('POST', `/v1/users/${u.username}/disable`);
```

## Безопасность

- Ключ даёт полное управление пользователями прокси. Храните его как пароль
  и не встраивайте в клиентские приложения — только в серверную часть.
- Снаружи используйте HTTPS (`API_TLS selfmask`): без него ключ идёт
  открытым текстом. Если Selfmask нет, держите API на `127.0.0.1` и
  обращайтесь через SSH-туннель или свой обратный прокси с TLS.
- Ограничьте адреса (`API_ALLOW`), если интегратор один.
- Служба работает от непривилегированного пользователя `mtproxyl-api`, а sudo
  разрешён только на команды пользователей, статус и перезапуск. Сеть,
  firewall, режимы и остальные настройки сервера через API недоступны.
- Каждый запрос пишется в журнал службы (адрес, метод, путь, код, время)
  без заголовков и тела: `journalctl -u mtproxyl-api`.
- Подозреваете утечку — `mtproxyl api key`: старый ключ перестаёт работать
  сразу.

## Устройство и диагностика

```
клиент ──HTTP(S)──▶ mtproxyl-api (пользователь mtproxyl-api)
                        │ sudo -n /opt/mtproxyl/mtproxyl.sh secret …
                        ▼
                    MTProxyL ──▶ конфиг движка / конфиг цели ──▶ telemt
```

| Файл | Назначение |
| --- | --- |
| `/usr/local/bin/mtproxyl-api` | Бинарник (выходит с релизами панели) |
| `/etc/systemd/system/mtproxyl-api.service` | Служба |
| `/etc/mtproxyl-api/key.sha256` | Хеш ключа |
| `/etc/mtproxyl-api/tls/` | Копия сертификата Selfmask для HTTPS |
| `/etc/sudoers.d/mtproxyl-api` | Разрешённые команды |

Чтение (`GET /v1/users`, `GET /v1/users/{username}`, `/links`) отвечает из
кэша: список с ссылками и живыми данными берётся одним запуском MTProxyL и
держится, пока не изменились `secrets.conf` и `settings.conf`. Правки из меню,
панели и других клиентов видны сразу. Трафик и живые подключения обновляются
в фоне раз в 10 секунд, поэтому могут отставать на это время.

Те же операции доступны и из командной строки сервера:

| API | CLI |
| --- | --- |
| `POST /v1/users` | `mtproxyl secret add <имя> [секрет]` |
| лимиты | `mtproxyl secret setlimits <имя> <соед> <ip> <квота> [срок]` |
| скорость | `mtproxyl secret setrate <имя> <вверх> <вниз>` (`10M`, `512k`, `0`) |
| метка | `mtproxyl secret adtag <имя> <32hex\|remove>` |
| `reset-quota` | `mtproxyl secret reset-quota <имя>` |
| `reset-traffic` | `mtproxyl stats reset user <имя>` |

Если что-то не работает:

```bash
mtproxyl api status
systemctl status mtproxyl-api
journalctl -u mtproxyl-api -n 50
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:9190/v1/health
```

- `401` при верном ключе — ключ сменили (`mtproxyl api key`) или в заголовке
  лишние символы.
- `422` с сообщением о нехватке прав sudo — правила устарели после обновления:
  выполните `mtproxyl api on` ещё раз, он их перепишет.
- Нет ответа снаружи — проверьте `API_LISTEN` (не `127.0.0.1`), firewall
  провайдера и `API_ALLOW`.
