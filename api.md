# API управления MTProxyL

`mtproxyl-api` — HTTP API для управления MTProxyL из других проектов: ботов
продажи доступа, личных кабинетов, CRM, скриптов мониторинга. Через него
создают, меняют и удаляют пользователей прокси, задают им все лимиты (число
соединений, уникальных IP, квоту трафика, срок действия, скорость, рекламную
метку), получают ссылки и состояние прокси.

- По умолчанию **выключен**. Включается одной командой на сервере.
- Работает **без веб-панели** — это отдельная служба.
- Работает в обоих режимах MTProxyL: **Manager** и **Reanimator**.
- Имена полей совпадают с API telemt, чтобы интеграцию не приходилось
  держать в двух вариантах.

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

- Тело запросов и ответов — JSON (`Content-Type: application/json`), UTF-8.
- Тело запроса — не больше 64 КБ. Неизвестные поля отклоняются с `400`: так
  опечатка в имени поля не превращается в молча проигнорированную правку.
- Успех:

```json
{ "ok": true, "data": { … } }
```

- Ошибка:

```json
{ "ok": false, "error": { "code": "not_found", "message": "Секрет 'bob' не найден" } }
```

`message` — текст для человека (на русском), `code` — для программы.

Имя пользователя (`username`): латиница, цифры, `_` и `-`, первая — буква
или цифра, до 32 символов.

Запросы, меняющие состояние, выполняются по одному: параллельные ждут
очереди. Одна операция обычно занимает 1–3 секунды (MTProxyL пересобирает
конфиг движка и перечитывает его без разрыва соединений).

## Объект пользователя

```json
{
  "username": "alice",
  "secret": "5ec993f420bc4f580ebc8b7d8dc1e43d",
  "enabled": true,
  "max_tcp_conns": 8,
  "max_unique_ips": 3,
  "data_quota_bytes": 10737418240,
  "expiration_rfc3339": "2027-01-31T23:59:59Z",
  "user_ad_tag": "",
  "rate_limit_up_bps": 0,
  "rate_limit_down_bps": 20000000,
  "notes": "",
  "created": 1791715149,
  "traffic": { "in_bytes": 1048576, "out_bytes": 52428800, "total_bytes": 53477376 },
  "links": [
    "tg://proxy?server=proxy.example.com&port=443&secret=ee5ec9…",
    "tg://webproxy?server=web.example.com&secret=dd5ec9…"
  ]
}
```

| Поле | Тип | Описание |
| --- | --- | --- |
| `username` | string | Имя (метка) пользователя |
| `secret` | string | Секрет, 32 hex. Ссылки строятся из него |
| `enabled` | bool | Выключенный пользователь не может подключиться, но не удаляется |
| `max_tcp_conns` | int | Одновременных TCP-соединений. `0` — без ограничения |
| `max_unique_ips` | int | Уникальных IP. `0` — без ограничения |
| `data_quota_bytes` | int | Квота трафика в байтах. `0` — без ограничения |
| `expiration_rfc3339` | string | Срок действия, RFC3339. Пусто — бессрочно |
| `user_ad_tag` | string | Своя рекламная метка (32 hex от @MTProxybot). Пусто — общая |
| `rate_limit_up_bps` | int | Скорость от клиента, бит/с. `0` — без ограничения. Нужен telemt 3.4.1+ |
| `rate_limit_down_bps` | int | Скорость к клиенту, бит/с. `0` — без ограничения |
| `notes` | string | Заметка (только чтение через API) |
| `created` | int | Время создания, Unix-секунды (`0` у пользователей цели в Reanimator) |
| `traffic` | object | Накопленный MTProxyL трафик, байты: от клиента, к клиенту, всего |
| `links` | string[] | Рабочие ссылки: `tg://proxy` на каждый включённый вид и `tg://webproxy`, если включён WEB Proxy. В списке — только с `?links=1` |

Скорость в бит/с: 10 Мбит/с = `10000000`, 512 кбит/с = `512000`. Максимум —
100 Гбит/с.

## Методы

| Метод | Путь | Что делает |
| --- | --- | --- |
| `GET` | `/v1/health` | Проверка ключа и доступности |
| `GET` | `/v1/status` | Состояние прокси |
| `POST` | `/v1/proxy/restart` | Перезапуск прокси |
| `GET` | `/v1/users` | Список пользователей |
| `POST` | `/v1/users` | Создать пользователя |
| `GET` | `/v1/users/{username}` | Один пользователь со ссылками |
| `PATCH` | `/v1/users/{username}` | Изменить переданные поля |
| `DELETE` | `/v1/users/{username}` | Удалить |
| `POST` | `/v1/users/{username}/enable` | Включить |
| `POST` | `/v1/users/{username}/disable` | Выключить |
| `POST` | `/v1/users/{username}/rotate-secret` | Новый секрет |
| `POST` | `/v1/users/{username}/reset-quota` | Обнулить израсходованную квоту |
| `POST` | `/v1/users/{username}/reset-traffic` | Сбросить накопленный трафик и историю IP |
| `GET` | `/v1/users/{username}/links` | Ссылки |

### `GET /v1/health`

Ничего не делает, кроме проверки ключа. Удобно для проверки интеграции.

```json
{ "ok": true, "data": { "status": "ok", "api_version": "1.3.0" } }
```

### `GET /v1/status`

Состояние прокси — тот же JSON, что `mtproxyl status --json`:

```json
{
  "ok": true,
  "data": {
    "version": "1.7.0", "mode": "manager", "status": "running",
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

Массив [объектов пользователя](#объект-пользователя). Ссылки не входят —
каждая требует отдельного вызова; добавьте `?links=1`, если они нужны всем
(на больших списках это заметно дольше).

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
- `expiration_rfc3339` — полная дата RFC3339 или `ГГГГ-ММ-ДД` (до конца этого
  дня по UTC).
- `enabled: false` — создать сразу выключенным.

Ответ — `201` и пользователь со ссылками. Если лимит не прошёл проверку,
пользователь не остаётся наполовину созданным: он удаляется, а в ответе — ошибка.

### `GET /v1/users/{username}`

Пользователь со ссылками. `404`, если такого нет.

### `PATCH /v1/users/{username}`

Меняет **только переданные** поля, остальные остаются как были. Можно
передать любые поля из создания, кроме `secret`.

```json
{ "data_quota_bytes": 21474836480, "expiration_rfc3339": "2027-02-28" }
```

- Снять ограничение — передать `0` (для срока и метки — пустую строку `""`).
- `username` с новым значением — переименование. Выполняется последним:
  если другая правка не прошла, имя остаётся прежним. Секрет и ссылки при
  переименовании не меняются.
- Секрет меняется только через `rotate-secret` — `secret` в PATCH даёт `400`.

Ответ — пользователь со ссылками (уже под новым именем, если меняли).

### `DELETE /v1/users/{username}`

```json
{ "ok": true, "data": { "username": "alice", "deleted": "true" } }
```

В Manager последнего пользователя удалить нельзя — `409`: движок без
пользователей не запускается.

### `POST /v1/users/{username}/enable`, `/disable`

Включает или выключает пользователя. Ответ — пользователь со ссылками.

### `POST /v1/users/{username}/rotate-secret`

Выдаёт новый секрет. Старые ссылки сразу перестают работать. Ответ —
пользователь с новыми ссылками.

### `POST /v1/users/{username}/reset-quota`

Обнуляет израсходованную квоту: её считает сам движок, и сброс идёт через
его API. Нужен включённый API движка (по умолчанию включён). Накопленный
MTProxyL трафик не меняется.

```json
{ "ok": true, "data": { "username": "alice", "quota": "reset" } }
```

Типичный сценарий продления подписки — сбросить квоту и сдвинуть срок:

```bash
curl -X POST  …/v1/users/alice/reset-quota
curl -X PATCH …/v1/users/alice -d '{"expiration_rfc3339":"2027-03-31"}'
```

### `POST /v1/users/{username}/reset-traffic`

Сбрасывает накопленную MTProxyL статистику пользователя: трафик и историю IP.
Квоту движка не трогает — для неё `reset-quota`.

### `GET /v1/users/{username}/links`

```json
{ "ok": true, "data": { "username": "alice", "links": ["tg://proxy?…", "tg://webproxy?…"] } }
```

## Коды ошибок

| HTTP | `code` | Когда |
| --- | --- | --- |
| `400` | `bad_request` | Неверное имя, неизвестное поле, неверный формат значения |
| `401` | `unauthorized` | Нет ключа или ключ неверный |
| `403` | `forbidden` | Адрес не входит в `API_ALLOW` |
| `404` | `not_found` | Пользователь не найден |
| `409` | `already_exists` | Пользователь с таким именем уже есть |
| `409` | `conflict` | Нельзя удалить последнего пользователя |
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
  | jq -r '.data.links[0]'

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

user = call("POST", "/v1/users", json={
    "username": "tg_123456789",
    "max_unique_ips": 3,
    "data_quota_bytes": 50 * 1024**3,
    "expiration_rfc3339": "2026-11-11",
})
print(user["links"])

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
