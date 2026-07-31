# Zapret2 MTProto fix — ручная установка

Серверный обход блокировки MTProto-прокси: `nfqws2` из [zapret2](https://github.com/bol-van/zapret2)
перехватывает пакеты прокси через NFQUEUE и применяет к первому пакету клиента
disorder + badsum, а к SYN+ACK и пустым ACK — контроль TCP-окна. Клиенту ничего
устанавливать не нужно, всё делается на сервере.

Эта инструкция — для ручной установки. В MTProxyL то же самое ставится из меню
`NFT лимитер, Zapret2 и фиксы` → `Zapret2 MTProto fix`; если вы пользуетесь
менеджером, ставьте оттуда — он же следит за портом, очередью и удалением.

> Все параметры ниже приведены со значениями по умолчанию. Они подобраны под
> работающую схему: длина частей 400, окно в SYN+ACK 1400, окно в пустых ACK 10,
> очередь NFQUEUE 200. **Менять их не нужно** — при других значениях дробление
> ClientHello перестаёт работать.

Ниже используется порт прокси `443`. Если ваш прокси слушает другой порт,
замените `443` в конфиге и в правилах nftables — это единственное, что зависит
от вашей установки.

---

## Что получится

| Что | Где |
|-----|-----|
| Бинарник и Lua-библиотеки | `/opt/mtproxyl-zapret2/` |
| Конфиг `nfqws2` | `/etc/mtproxyl-zapret2/mtproto.conf` |
| Lua-скрипт обхода | `/opt/mtproxyl-zapret2/lua/mtproto.lua` |
| Скрипт правил + запуска | `/usr/local/sbin/mtproxyl-zapret2-start.sh` |
| Служба | `mtproxyl-zapret2.service` |
| Таблица nftables | `ip MTProtoL` |

---

## 1. Зависимости

```bash
apt-get update && apt-get install -y nftables curl tar     # Debian/Ubuntu
# dnf install -y nftables curl tar                         # RHEL/Alma/Rocky
```

Модуль очереди подгружается ядром сам, но проверить можно так:

```bash
modprobe nfnetlink_queue
```

---

## 2. Бинарник и Lua-библиотеки

```bash
ARCH=linux-x86_64            # для ARM64: linux-arm64
VER=v1.0.3

curl -fsSL -o /tmp/zapret2.tar.gz \
  "https://github.com/bol-van/zapret2/releases/download/${VER}/zapret2-${VER}.tar.gz"

mkdir -p /tmp/zapret2-unpack /opt/mtproxyl-zapret2/bin /opt/mtproxyl-zapret2/lua /etc/mtproxyl-zapret2
tar xzf /tmp/zapret2.tar.gz -C /tmp/zapret2-unpack
ROOT=$(find /tmp/zapret2-unpack -maxdepth 1 -mindepth 1 -type d | head -1)

cp -f "${ROOT}/binaries/${ARCH}/nfqws2" /opt/mtproxyl-zapret2/bin/
chmod +x /opt/mtproxyl-zapret2/bin/nfqws2

# Lua-библиотеки самого zapret2 (в архиве лежат в nfq2/lua, реже в lua/ или nfq/lua)
LUA=$(for d in "${ROOT}/nfq2/lua" "${ROOT}/lua" "${ROOT}/nfq/lua"; do
        ls "$d"/zapret-lib.lua* >/dev/null 2>&1 && echo "$d" && break; done)
cp -f "${LUA}"/zapret-lib.lua*      /opt/mtproxyl-zapret2/lua/
cp -f "${LUA}"/zapret-antidpi.lua*  /opt/mtproxyl-zapret2/lua/

rm -rf /tmp/zapret2.tar.gz /tmp/zapret2-unpack
/opt/mtproxyl-zapret2/bin/nfqws2 --version
```

---

## 3. Конфиг `nfqws2`

`/etc/mtproxyl-zapret2/mtproto.conf`:

```
--qnum 200
--fwmark=0x40000000
--server

--lua-init=@/opt/mtproxyl-zapret2/lua/zapret-lib.lua
--lua-init=@/opt/mtproxyl-zapret2/lua/zapret-antidpi.lua
--lua-init=@/opt/mtproxyl-zapret2/lua/mtproto.lua
--filter-tcp=443
--out-range=a
--in-range=a
--payload-disable=all
--lua-desync=lets_resend
--new
```

Что здесь важно:

- `--qnum 200` — номер очереди NFQUEUE, тот же номер стоит в правилах nftables.
  Если очередь 200 занята другим процессом (`cat /proc/net/netfilter/nfnetlink_queue`),
  возьмите свободный номер и поменяйте его **и здесь, и в правилах**.
- `--fwmark=0x40000000` — метка, которой `nfqws2` помечает свои же пакеты, чтобы
  не обрабатывать их повторно.
- `--filter-tcp=443` — порт прокси. Несколько портов и диапазоны перечисляются
  через запятую: `--filter-tcp=443,8443,9000-9100`.

---

## 4. Lua-скрипт

`/opt/mtproxyl-zapret2/lua/mtproto.lua`:

```lua
-- Zapret2 MTProto fix
-- Серверный обход: disorder + badsum + window control + iOS fwmark bypass

function lets_resend(ctx, desync)
    -- iOS fingerprint bypass: пропускаем через fwmark без обработки
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == TH_SYN then
        if desync.dis.tcp.th_win == 65535 and
           #desync.dis.tcp.options == 8 and
           desync.dis.tcp.options[1].kind == 2 and
           desync.dis.tcp.options[2].kind == 1 and
           desync.dis.tcp.options[3].kind == 3 and
           desync.dis.tcp.options[4].kind == 1 and
           desync.dis.tcp.options[5].kind == 1 and
           desync.dis.tcp.options[6].kind == 8 and
           desync.dis.tcp.options[7].kind == 4 and
           desync.dis.tcp.options[8].kind == 0 then
            instance_cutoff(ctx, nil)
            desync.arg.fwmark = 0x40000
            rawsend_dissect_segmented(desync)
            return VERDICT_DROP
        end
    end

    -- SYN+ACK: запоминаем ack и зажимаем окно
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
        desync.track.lua_state["ack0"] = desync.dis.tcp.th_ack
        desync.dis.tcp.th_win = 1400
        return VERDICT_MODIFY
    end

    -- Пустые ACK: зажимаем окно, отпускаем после первого payload
    if direction_check(desync) and bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_ACK) then
        local ack0 = desync.track and desync.track.lua_state["ack0"]
        if ack0 and (desync.dis.tcp.th_ack - ack0 >= 1400) then
            instance_cutoff(ctx, true)
            desync.arg.fwmark = 0x40000
            rawsend_dissect_segmented(desync)
            return VERDICT_DROP
        end
        desync.dis.tcp.th_win = 10
        return VERDICT_MODIFY
    end

    -- Только первый data-пакет клиента
    if #desync.dis.payload == 0 or desync.track == nil or desync.track.pos.client.tcp.rseq ~= 1 then
        return VERDICT_PASS
    end

    -- Split на 3 части, средняя с badsum (disorder)
    local len = 400
    local first  = string.sub(desync.dis.payload, 1, len)
    local second = string.sub(desync.dis.payload, len + 1, 2 * len)
    local third  = string.sub(desync.dis.payload, 2 * len + 1)
    rawsend_payload_segmented(desync, first)
    rawsend_payload_segmented(desync, third, 2 * len)
    desync.arg["badsum"] = true
    rawsend_payload_segmented(desync, second, len)
    instance_cutoff(ctx, false)
    return VERDICT_DROP
end
```

Как это работает по шагам:

| Шаг | Что происходит |
|-----|----------------|
| 1 | SYN+ACK уходит с `window=1400` — клиент вынужден дробить ClientHello |
| 2 | Пустые ACK идут с `window=10`, пока клиент не отправил payload |
| 3 | Первый data-пакет режется на 3 части: первая уходит нормально, третья со смещением, средняя — с битой контрольной суммой |
| 4 | DPI не может собрать ClientHello и пропускает соединение |
| 5 | Клиент ретрансмитит среднюю часть — соединение устанавливается |
| 6 | Дальнейший трафик идёт без вмешательства |

iOS-клиенты определяются по TCP SYN fingerprint и уходят через `fwmark` без
манипуляций с окном — у них такая схема ломает соединение.

---

## 5. Правила nftables и запуск

Правила и сам демон живут в одном скрипте: nftables-таблица создаётся заново при
каждом старте службы, чтобы не зависеть от порядка загрузки.

`/usr/local/sbin/mtproxyl-zapret2-start.sh`:

```bash
#!/bin/bash
set -e

TABLE="MTProtoL"
FWMARK="0x40000000"
PORT="443"
QNUM="200"
CT_MARK="0x00040000"
COMBINED_MARK="0x40040000"

nft delete table ip "$TABLE" 2>/dev/null || true
nft add table ip "$TABLE"

nft "add chain ip $TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip $TABLE predefrag meta mark $COMBINED_MARK counter accept"
nft "add rule ip $TABLE predefrag meta mark and $FWMARK != 0x00000000 counter notrack"

nft "add chain ip $TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip $TABLE output meta mark and $COMBINED_MARK == $COMBINED_MARK ct mark set $CT_MARK counter accept"

nft "add chain ip $TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
nft "add rule ip $TABLE postrouting ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE postrouting meta mark and $FWMARK == 0x00000000 tcp sport $PORT counter queue num $QNUM bypass"

nft "add chain ip $TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add rule ip $TABLE prerouting ct state invalid counter drop"
nft "add rule ip $TABLE prerouting ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE prerouting meta mark and $FWMARK == 0x00000000 tcp dport $PORT counter queue num $QNUM bypass"

echo "NFT table $TABLE applied (port=$PORT qnum=$QNUM)"

exec /opt/mtproxyl-zapret2/bin/nfqws2 @/etc/mtproxyl-zapret2/mtproto.conf
```

```bash
chmod +x /usr/local/sbin/mtproxyl-zapret2-start.sh
```

`/etc/systemd/system/mtproxyl-zapret2.service`:

```ini
[Unit]
Description=MTProxyL Zapret2 MTProto fix
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mtproxyl-zapret2-start.sh
ExecStop=/usr/sbin/nft delete table ip MTProtoL
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Запуск:

```bash
systemctl daemon-reload
systemctl enable --now mtproxyl-zapret2.service
```

---

## 6. Проверка

```bash
systemctl status mtproxyl-zapret2.service
nft list table ip MTProtoL          # правила на месте, счётчики растут под нагрузкой
cat /proc/net/netfilter/nfnetlink_queue   # очередь 200 в списке
journalctl -u mtproxyl-zapret2 -n 30 --no-pager
```

Отдельно стоит проверить TCP-окно. Реальное окно в пустых ACK равно
`10 × 2^wscale`, где `wscale` считается ядром из размера буфера приёма, и оно
должно остаться **меньше 1400 байт**:

```bash
sysctl -n net.core.rmem_max net.ipv4.tcp_rmem
```

При `net.core.rmem_max` порядка 8 МБ и больше `wscale` вырастает, окно уходит за
1400 байт и дробление перестаёт работать. Приводится это в порядок уменьшением
буфера, а не правкой окна:

```bash
sysctl -w net.core.rmem_max=8388608
sysctl -w net.ipv4.tcp_rmem='4096 131072 8388608'
```

---

## 7. Удаление

```bash
systemctl disable --now mtproxyl-zapret2.service
rm -f /etc/systemd/system/mtproxyl-zapret2.service
rm -f /usr/local/sbin/mtproxyl-zapret2-start.sh
systemctl daemon-reload
nft delete table ip MTProtoL 2>/dev/null || true
rm -rf /opt/mtproxyl-zapret2 /etc/mtproxyl-zapret2
```

---

## Приложение: прокси в Docker с сетью bridge

Если прокси работает в контейнере с `--network bridge` (а не `host`), трафик до
него проходит не через `prerouting`/`postrouting` хоста, а через `forward`.
В этом случае в скрипте из шага 5 замените блоки `postrouting` и `prerouting` на:

```bash
nft "add chain ip $TABLE forward { type filter hook forward priority mangle; policy accept; }"
nft "add rule ip $TABLE forward ct state invalid counter drop"
nft "add rule ip $TABLE forward ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE forward meta mark and $FWMARK == 0x00000000 tcp dport $PORT counter queue num $QNUM bypass"
nft "add rule ip $TABLE forward meta mark and $FWMARK == 0x00000000 tcp sport $PORT counter queue num $QNUM bypass"
```

Правила без фильтра по IP контейнера — так надёжнее: IP контейнера меняется при
пересоздании, и правила не приходится переналагать. Службе в этом случае нужен
запуск после Docker — добавьте `docker.service` в `After=` и `Wants=` юнита.
