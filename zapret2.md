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
| Параметры ядра | `/etc/sysctl.d/99-mtproxyl-zapret2.conf` |

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

### Как это работает

**1. SYN клиента — проверка fingerprint.** iOS-клиенты узнаются по набору TCP-опций
в SYN и уходят через `fwmark` без вмешательства: описанная ниже схема им не нужна. Остальные идут дальше по сценарию.

**2. SYN+ACK — зажимаем окно.** Вместо реального окна (десятки килобайт) сервер
объявляет `1400` байт. Одновременно запоминается `ack0` — номер, от которого
дальше считается прогресс клиента.

**3. Клиент отдаёт ClientHello по частям.** Целиком он в объявленное окно не
влезает, и ядро Linux отправляет половину окна — в примере ниже 700 байт.
Это и есть первый data-пакет, который мы перехватываем.

**4. Режем первый пакет.** Длина части — `400`, поэтому 700 байт распадаются так:

| Часть | Длина | Как отправляется |
|-------|-------|------------------|
| 1 | 400 | как есть, со смещением 0 |
| 2 | 300 | с **битой контрольной суммой**, со смещением 400 |
| 3 | 0 | пустая — данных на неё не осталось (700 < 800) |

Отправляются они в порядке 1 → 3 → 2, оригинальный пакет дропается. Для DPI поток
рвётся на испорченной части: собрать по нему корректный ClientHello не получается,
а конечный получатель битый сегмент просто отбрасывает.

**5. Остаток догоняет в зажатом окне.** Дальше пустые ACK идут с окном `10`, и
клиент досылает оставшийся ClientHello мелкими порциями — вместо «третьей части»
в поток встаёт его же следующий пакет. Скрипт на каждом ACK считает
`delta = th_ack − ack0`.

**6. Отпускаем соединение.** Как только `delta` достигает `1400` — то есть весь
объявленный объём подтверждён, — соединение помечается `fwmark` и снимается с
обработки: дальше трафик идёт мимо очереди, без вмешательства.

Пример отладочного вывода одной сессии (адреса скрыты). В поставляемом скрипте
логирования нет — вывод приведён с отладочной версией, чтобы показать
последовательность:

```
LUA: mtproto: SYN win=65535 src=<клиент>:2351 dst=<сервер>:443
LUA: mtproto: SYN fingerprint NOT ios, options_count=5
LUA: mtproto: SYN,ACK seq=2112125609 ack=678852406 -> saved ack0, forcing win 1400 (was 65160)
LUA: mtproto: SPLIT first data-packet, total_len=700
LUA: mtproto:   part1 (send normal)  len=400 hex_head=16 03 01 06 F9 01 00 06 F5 03 03 B3 80 AE 56 14
LUA: mtproto:   part2 (send BADSUM)  len=300 hex_head=F2 F4 4B 8D 69 64 5E 59 80 B4 49 39 41 C5 AF 02
LUA: mtproto:   part3 (send normal)  len=0 hex_head=
LUA: mtproto:   -> part1 sent, offset=0
LUA: mtproto:   -> part3 sent, offset=800
LUA: mtproto:   -> part2 (badsum) sent, offset=400
LUA: mtproto: SPLIT done, original dropped, incoming cutoff for this stream
LUA: mtproto: ACK th_ack=678852806 ack0_type=number ack0=678852406 delta=400 payload_len=0
LUA: mtproto: threshold not reached -> keep win=10 (was 506)
LUA: mtproto: ACK th_ack=678852806 ack0_type=number ack0=678852406 delta=400 payload_len=0
LUA: mtproto: threshold not reached -> keep win=10 (was 528)
LUA: mtproto: ACK th_ack=678853806 ack0_type=number ack0=678852406 delta=1400 payload_len=0
LUA: mtproto: threshold >=1400 REACHED (delta=1400) -> release + fwmark tag
```

Отсюда же видно, почему значения связаны между собой: окно в SYN+ACK задаёт и
размер первого пакета клиента, и порог отпускания, а длина части определяет, как
этот пакет разложится. Поэтому их и не стоит менять по отдельности.

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
# Мимо очереди пропускаем только пакеты с данными — см. пояснение ниже.
BYPASS_MATCH="tcp flags & (fin | syn | rst | ack) == ack"

# Переиспользование сокета в TIME_WAIT для нового соединения.
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true

nft delete table ip "$TABLE" 2>/dev/null || true
nft add table ip "$TABLE"

nft "add chain ip $TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip $TABLE predefrag meta mark $COMBINED_MARK counter accept"
nft "add rule ip $TABLE predefrag meta mark and $FWMARK != 0x00000000 counter notrack"

nft "add chain ip $TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip $TABLE output meta mark and $COMBINED_MARK == $COMBINED_MARK ct mark set $CT_MARK counter accept"

nft "add chain ip $TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
nft "add rule ip $TABLE postrouting $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE postrouting meta mark and $FWMARK == 0x00000000 tcp sport $PORT counter queue num $QNUM bypass"

nft "add chain ip $TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add rule ip $TABLE prerouting ct state invalid counter drop"
nft "add rule ip $TABLE prerouting $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE prerouting meta mark and $FWMARK == 0x00000000 tcp dport $PORT counter queue num $QNUM bypass"

echo "NFT table $TABLE applied (port=$PORT qnum=$QNUM)"

exec /opt/mtproxyl-zapret2/bin/nfqws2 @/etc/mtproxyl-zapret2/mtproto.conf
```

Чтобы `tcp_tw_reuse` пережил перезагрузку, положите его ещё и в sysctl.d:

```bash
cat > /etc/sysctl.d/99-mtproxyl-zapret2.conf << 'EOF'
net.ipv4.tcp_tw_reuse = 1
EOF
```

### Почему обход очереди ловит только ACK

Разгрузка держится на том, что соединение, которое `nfqws2` уже разобрал,
помечается в conntrack (`ct mark`) и дальше идёт мимо очереди. Но выпускать
мимо неё можно только пакеты с данными: если мимо пройдёт и FIN, `nfqws2` не
увидит закрытия и оставит соединение в своём conntrack живым.

За NAT, тем более CGNAT, это оборачивается разрывами. Клиент за NAT не выбирает
порт сам: трансляция берёт его из небольшого пула и переиспользует сразу после
закрытия, которое отследила по FIN. Для `nfqws2` новое подключение выглядит как
SYN внутри соединения, которое он всё ещё считает установленным, и
обрабатывается по устаревшему состоянию.

Поэтому в обеих цепочках стоит `tcp flags & (fin | syn | rst | ack) == ack`:
мимо очереди идут только пакеты, у которых из этих четырёх флагов поднят один
ACK. FIN, SYN и RST продолжают попадать в `nfqws2` — на объём трафика это не
влияет, их единицы на соединение.

`net.ipv4.tcp_tw_reuse=1` закрывает ту же дыру со стороны ядра: у него на месте
закрытого соединения остаётся сокет в TIME_WAIT, и на SYN со свежезакрытого
кортежа оно отвечает ACK вместо того, чтобы открыть новое соединение. Значение
по умолчанию на свежих ядрах — `2` (только loopback), нужна `1`.

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
sysctl -n net.ipv4.tcp_tw_reuse     # должна быть 1
```

В обеих цепочках правило обхода должно выглядеть так — с проверкой флагов, а не
только `ct mark`:

```
tcp flags & (fin | syn | rst | ack) == ack ct mark 0x00040000 counter accept
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
rm -f /etc/sysctl.d/99-mtproxyl-zapret2.conf
sysctl -w net.ipv4.tcp_tw_reuse=2 >/dev/null   # значение ядра по умолчанию
```

---

## Приложение: прокси в Docker с сетью bridge

Если прокси работает в контейнере с `--network bridge` (а не `host`), трафик до
него проходит не через `prerouting`/`postrouting` хоста, а через `forward`.
В этом случае в скрипте из шага 5 замените блоки `postrouting` и `prerouting` на:

```bash
nft "add chain ip $TABLE forward { type filter hook forward priority mangle; policy accept; }"
nft "add rule ip $TABLE forward ct state invalid counter drop"
nft "add rule ip $TABLE forward $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE forward meta mark and $FWMARK == 0x00000000 tcp dport $PORT counter queue num $QNUM bypass"
nft "add rule ip $TABLE forward meta mark and $FWMARK == 0x00000000 tcp sport $PORT counter queue num $QNUM bypass"
```

Правила без фильтра по IP контейнера — так надёжнее: IP контейнера меняется при
пересоздании, и правила не приходится переналагать. Службе в этом случае нужен
запуск после Docker — добавьте `docker.service` в `After=` и `Wants=` юнита.
