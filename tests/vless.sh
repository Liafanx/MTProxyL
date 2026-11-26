#!/bin/bash
# VLESS: разбор ссылок, список и подписка, конфиг Xray, upstream движка,
# конфликты с другими выходами, переключение по отказу.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

INSTALL_DIR="$t"
mkdir -p "$INSTALL_DIR/vless"
VERSION=test
source "$repo/lib/colors.sh" 2>/dev/null || true
for l in utils settings detect vless tui_vless; do source "$repo/lib/$l.sh" || fail "source $l"; done
log_info() { :; }; log_success() { :; }; log_warn() { :; }
log_error() { echo "ERR: $*" >&2; }
check_root() { :; }
draw_header() { echo "$*"; }
save_settings() { :; }
press_any_key() { :; }

# Фейковое ядро: version и run -test.
cat > "$(_vless_bin)" <<'BIN'
#!/bin/sh
[ "$1" = version ] && { echo "Xray 26.11.9 (test)"; exit 0; }
[ "$1" = run ] && exit 0
exit 0
BIN
chmod 755 "$(_vless_bin)"

# Заглушки движка и upstream.
UPSTREAM_NAMES=(); UPSTREAM_ENABLED=(); UPSTREAM_SCOPES=()
load_upstreams() { :; }
upstream_add() { echo "add $1 $2 $3 $6 $8" >> "$t/up.log"; }
upstream_remove() { echo "rm $1" >> "$t/up.log"; }
upstream_toggle() { echo "toggle $1 $2" >> "$t/up.log"; }
generate_telemt_config() { :; }; is_proxy_running() { return 1; }; restart_proxy_container() { :; }
mtdd_mgr_active() { return 1; }
systemctl() {
    case "$1" in
        is-active) echo active ;;
        *) return 0 ;;
    esac
}
vless_watchdog_install() { :; }
warp_disable() { echo "warp-off" >> "$t/conf.log"; }
donor_load() { DONOR_ENABLED=false; }
donor_disable() { echo "donor-off" >> "$t/conf.log"; }
awg_is_enabled() { return 1; }

URI1='vless://11111111-1111-1111-1111-111111111111@example.org:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.org&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab12&type=tcp#Reality'
URI2='vless://22222222-2222-2222-2222-222222222222@example.net:8443?encryption=none&security=tls&sni=example.net&type=ws&path=%2Fws%3Fed%3D2048&host=example.net#WS'

# Разбор: публичный VLESS без TLS запрещён, Reality принимается.
python3 -I "$repo/lib/vless_parse.py" check 'vless://u@example.org:443?security=none&type=tcp' >/dev/null 2>&1 \
    && fail "VLESS без TLS принят"
python3 -I "$repo/lib/vless_parse.py" check "$URI1" >/dev/null || fail "Reality не разобран"
python3 -I "$repo/lib/vless_parse.py" check "$URI2" >/dev/null || fail "WS не разобран"

# Список и маска.
vless_link_add "$URI1" Reality >/dev/null || fail "add 1"
vless_link_add "$URI2" WS >/dev/null || fail "add 2"
vless_link_add "$URI1" Reality >/dev/null || fail "повтор add"
[ "$(grep -c . "$(_vless_links)")" = 2 ] || fail "дубликат ссылки"
ID1=$(_vless_uri_id "$URI1")
mask=$(_vless_mask_uri "$(_vless_link_uri "$ID1")")
[[ "$mask" != *11111111* && "$mask" != *AAAAAAAA* ]] || fail "маска светит секрет: $mask"

# Выбор ссылки при выключенном VLESS — успешная операция, а не exit 1.
VLESS_ENABLED=false
vless_link_use "$ID1" >/dev/null || fail "link use при выключенном VLESS"

# Конфиг под активную ссылку.
VLESS_ACTIVE=$ID1
vless_config_write || fail "config_write"
grep -q '"realitySettings"' "$(_vless_conf)" || fail "нет reality в конфиге"
grep -q "\"port\": $(_vless_port)" "$(_vless_conf)" || fail "нет socks-порта"
grep -q "$ID1" "$(_vless_conf)" && fail "id попал в конфиг"

# Включение: upstream socks5 + локальная замаскировка не нужна.
vless_on >/dev/null || fail "vless_on"
grep -q "add vless socks5 127.0.0.1:$(_vless_port) 1 " "$t/up.log" || fail "upstream не добавлен: $(cat "$t/up.log")"
grep -q '^add vlesslocal' "$t/up.log" && fail "лишний local-маршрут без локальной маскировки"
[ "$VLESS_ENABLED" = true ] || fail "enabled не выставлен"

# Повторное включение при включённом WARP: отказ без --yes, выключение с ним.
WARP_ENABLED=true
vless_on >/dev/null 2>&1 && fail "конфликт с WARP проигнорирован"
vless_on --yes >/dev/null 2>&1 || fail "vless on --yes"
grep -q warp-off "$t/conf.log" || fail "WARP не выключен"
WARP_ENABLED=false

# ME с VLESS несовместим: mtdd требует явного согласия.
mtdd_mgr_active() { return 0; }
vless_on >/dev/null 2>&1 && fail "mtdd без согласия на Direct"
vless_on --yes --allow-disable-me >/dev/null 2>&1 || fail "mtdd с согласием"
mtdd_mgr_active() { return 1; }

# Выключение: upstream снят.
vless_off >/dev/null || fail "vless_off"
grep -q '^rm vless$' "$t/up.log" || fail "upstream не снят"
[ "$VLESS_ENABLED" = false ] || fail "enabled не снят"

# Подписка: base64 из двух ссылок заменяет прошлые sub-ссылки, ручные целы.
URI3='vless://33333333-3333-3333-3333-333333333333@sub1.example.org:443?security=tls&sni=sub1.example.org&type=grpc&serviceName=grpc#Sub1'
URI4='vless://44444444-4444-4444-4444-444444444444@sub2.example.org:443?security=tls&sni=sub2.example.org&type=httpupgrade&path=%2Fup#Sub2'
cat > "$t/feed" <<EOF
$URI3
$URI4
EOF
base64 -w0 "$t/feed" > "$t/feed.b64"
curl() {
    local _out="" _hdr="" _prev=""
    printf '%s\n' "$@" >> "$t/curl.log"
    for a in "$@"; do
        [ "$_prev" = "-o" ] && _out="$a"
        [ "$_prev" = "-D" ] && _hdr="$a"
        _prev="$a"
    done
    : > "$_hdr" 2>/dev/null
    printf 'profile-title: VTest\n' > "$_hdr" 2>/dev/null
    cp "$t/feed.b64" "$_out" 2>/dev/null
    printf '200'
}
VLESS_ACTIVE=$ID1
vless_sub_set "https://example.org/sub" >/dev/null 2>&1 || fail "sub set"
[ "$(grep -c '|sub|' "$(_vless_links)")" = 2 ] || fail "sub-ссылки: $(cat "$(_vless_links)")"
grep -q '|manual|' "$(_vless_links)" || fail "ручные ссылки пропали"
# JSON-подписка (Xray): VLESS из outbounds, имена из remarks, прочее пропускается.
PBK=$(python3 -I -c 'import base64; print(base64.urlsafe_b64encode(b"0"*32).decode().rstrip("="))')
cat > "$t/sub.json" <<JSON
[{"remarks":"JSON node","outbounds":[
 {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"example.org","port":443,"users":[{"id":"77777777-7777-7777-7777-777777777777","encryption":"none"}]}]},"streamSettings":{"network":"xhttp","security":"reality","realitySettings":{"serverName":"example.org","publicKey":"$PBK","shortId":"ab12","fingerprint":"chrome"},"xhttpSettings":{"path":"/xhttp","mode":"auto"}}},
 {"tag":"hy","protocol":"hysteria"},
 {"tag":"block","protocol":"blackhole"}
]}]
JSON
python3 -I "$repo/lib/vless_parse.py" from-json "$t/sub.json" > "$t/sub.uris" || fail "from-json"
[ "$(grep -c '^vless://' "$t/sub.uris")" = 1 ] || fail "JSON: не один VLESS"
python3 -I "$repo/lib/vless_parse.py" check "$(cat "$t/sub.uris")" | jq -e '.security=="reality" and .transport=="xhttp" and .name=="JSON node"' >/dev/null || fail "JSON: поля VLESS"
cp "$t/sub.json" "$t/feed.b64"
vless_sub_refresh >/dev/null 2>&1 || fail "JSON-подписка"
[ "$(grep -c '|sub|' "$(_vless_links)")" = 1 ] || fail "JSON-ссылка не импортирована"
vless_sub_off >/dev/null || fail "sub off JSON"

# HWID: стабильный, допустимого формата, уходит заголовками вместе с UA Happ.
VLESS_HWID_ENABLED=true; VLESS_HWID=""
vless_sub_set "https://example.org/sub" >/dev/null 2>&1 || fail "sub set перед HWID"
h1=$(_vless_hwid); h2=$(_vless_hwid)
[ "$h1" = "$h2" ] || fail "HWID нестабилен"
[[ "$h1" =~ ^[A-Za-z0-9=-]{10,64}$ ]] || fail "HWID формат: $h1"
vless_sub_refresh >/dev/null 2>&1 || fail "sub refresh с HWID"
grep -qx -- "-A" "$t/curl.log" || fail "UA не задан"
grep -qx -- "Happ/3.23.0" "$t/curl.log" || fail "UA не Happ"
grep -qx -- "x-hwid: $h1" "$t/curl.log" || fail "x-hwid не передан"
grep -qx -- "X-Device-ID: $h1" "$t/curl.log" || fail "X-Device-ID не передан"
grep -q "VTest" "$(_vless_sub_title_file)" || fail "profile-title не сохранён"
: > "$t/curl.log"
VLESS_HWID_ENABLED=false
vless_sub_refresh >/dev/null 2>&1 || fail "sub refresh без HWID"
grep -q '^x-hwid:' "$t/curl.log" && fail "HWID отправлен при выключенном"
VLESS_HWID_ENABLED=true
# Ссылка-подсказка провайдера (0.0.0.0) не импортируется, текст сохраняется.
printf 'vless://55555555-5555-5555-5555-555555555555@0.0.0.0:443?security=none&type=tcp#Выберите приложение поддерживающие передачу HWID\n' > "$t/feed.raw"
base64 -w0 "$t/feed.raw" > "$t/feed.b64"
vless_sub_refresh >/dev/null 2>&1 || fail "sub refresh с подсказкой"
[ "$(grep -c '|sub|' "$(_vless_links)")" = 0 ] || fail "подсказка импортирована"
grep -q 'HWID' "$(_vless_sub_notice_file)" || fail "текст подсказки не сохранён"
vless_sub_off >/dev/null || fail "sub off"
vless_status_json | jq -e '(.hwid|length) > 0 and .hwid_enabled == true and (.sub_ua|length) > 0' >/dev/null || fail "status: HWID и UA"
# Состояние middle proxy видно в статусе: при VLESS и выключенном ME — disabled.
VLESS_ENABLED=true
_vless_me_enabled() { return 1; }
vless_status_json | jq -e '.me_state == "disabled"' >/dev/null || fail "status: ME выключен"
VLESS_ENABLED=false

# Отказ: первые две проверки — перезапуск, четвёртая — смена ссылки.
VLESS_ENABLED=true
VLESS_ACTIVE=$ID1
vless_test_json() { echo '{"ok": false, "exit_ip": "", "telegram": "fail", "dc": "fail"}'; }
: > "$t/restart.log"
systemctl() {
    case "$1" in
        restart) echo restart >> "$t/restart.log" ;;
        is-active) echo active ;;
        *) return 0 ;;
    esac
}
vless_watch; vless_watch
[ "$(grep -c restart "$t/restart.log")" = 1 ] || fail "перезапуск после двух сбоев"
vless_watch; vless_watch
[ "$VLESS_ACTIVE" != "$ID1" ] || fail "не переключился на запасную ссылку"

echo "OK vless"
