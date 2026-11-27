#!/bin/bash
# VLESS: разбор ссылок, список и подписка, конфиг Xray, upstream движка,
# конфликты с другими выходами, переключение по отказу.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

INSTALL_DIR="$t"
UPSTREAMS_FILE="$INSTALL_DIR/upstreams.conf"
mkdir -p "$INSTALL_DIR/vless"
VERSION=test
source "$repo/lib/colors.sh" 2>/dev/null || true
for l in utils settings detect vless egress expert_mode tui_vless; do source "$repo/lib/$l.sh" || fail "source $l"; done
(
    load_secrets() { users_loaded=true; }
    load_upstreams() { upstreams_loaded=true; }
    mtdd_mgr_active() { return 0; }
    generate_mtdd_config() { [ "$users_loaded" = true ] && [ "$upstreams_loaded" = true ]; }
    mtdd_restart() { return 1; }
    if _vless_engine_apply; then fail "ошибка перезапуска mtdd потеряна"; fi
    [ "$users_loaded" = true ] && [ "$upstreams_loaded" = true ] || fail "перед применением не загружены пользователи и маршруты"
    systemctl() { return 1; }
    VLESS_ENABLED=true
    egress_status_json | jq -e '.via == "vless" and .ok == false' >/dev/null || fail "выключенный Xray не виден в статусе выхода"
) || exit 1
log_info() { :; }; log_success() { :; }; log_warn() { echo "WARN: $*" >&2; }
log_error() { echo "ERR: $*" >&2; }
check_root() { :; }
cli_lock() { :; }
cli_unlock() { :; }
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
# Проверка выхода в тесте не ходит в сеть.
vless_test_json() { jq -nc --argjson ok "${_test_online:-true}" '{ok: $ok}'; }

# Заглушки движка и upstream.
UPSTREAM_NAMES=(); UPSTREAM_ENABLED=(); UPSTREAM_SCOPES=()
load_secrets() { :; }
load_upstreams() { :; }
upstream_add() { echo "add $1 $2 $3 $6 $8" >> "$t/up.log"; }
upstream_remove() { echo "rm $1" >> "$t/up.log"; }
upstream_toggle() { echo "toggle $1 $2" >> "$t/up.log"; }
generate_telemt_config() { :; }; is_proxy_running() { return 1; }; restart_proxy_container() { :; }
_engine_calls=0
_vless_engine_apply() {
    if [ "${VLESS_DEFER_RESTART:-false}" = true ]; then VLESS_ENGINE_PENDING=true; return 0; fi
    _engine_calls=$((_engine_calls + 1))
    printf '%s %s\n' "$VLESS_ENABLED" "${1:-false}" >> "$t/engine.log"
    [ "${_test_engine_failure:-false}" != true ] || [ "$VLESS_ENABLED" != true ]
}
mtdd_mgr_active() { return 1; }
systemd-run() { echo "$*" >> "$t/systemd-run.log"; return 0; }
systemctl() {
    case "$1" in
        restart) echo restart >> "$t/restart.log" ;;
        disable) printf '%s\n' "$*" >> "$t/disable.log" ;;
        is-active) echo active ;;
        *) return 0 ;;
    esac
}
vless_watchdog_install() { :; }
_vless_unit_dir() { echo "$t/systemd"; }
mkdir -p "$t/systemd"
load_settings() { if [ -f "$t/warp-on" ]; then WARP_ENABLED=true; else WARP_ENABLED=false; fi; }
handle_warp_command() {
    case "$1" in
        off) rm -f "$t/warp-on"; echo "warp-off" >> "$t/conf.log" ;;
        on) [ "${_test_restore_failure:-false}" != true ] && touch "$t/warp-on" ;;
    esac
}
donor_load() { if [ -f "$t/donor-on" ]; then DONOR_ENABLED=true; else DONOR_ENABLED=false; fi; }
donor_disable() { rm -f "$t/donor-on"; }
donor_enable() { touch "$t/donor-on"; }
awg_is_enabled() { [ -f "$t/awg-on" ]; }
awg_load() { AWG_ME_DISABLED="${_test_awg_me_disabled:-}"; }
handle_awg_command() {
    case "$1" in
        off) rm -f "$t/awg-on" ;;
        on) touch "$t/awg-on" ;;
    esac
}

URI1='vless://11111111-1111-1111-1111-111111111111@example.org:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.org&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab12&type=tcp#Reality'
URI2='vless://22222222-2222-2222-2222-222222222222@example.net:8443?encryption=none&security=tls&sni=example.net&type=ws&path=%2Fws%3Fed%3D2048&host=example.net#WS'

# Разбор: публичный VLESS без TLS запрещён, Reality принимается.
bash "$repo/lib/vless_parse.sh" check 'vless://u@example.org:443?security=none&type=tcp' >/dev/null 2>&1 \
    && fail "VLESS без TLS принят"
bash "$repo/lib/vless_parse.sh" check "$URI1" >/dev/null || fail "Reality не разобран"
bash "$repo/lib/vless_parse.sh" check "$URI2" >/dev/null || fail "WS не разобран"

# Список и маска.
vless_link_add "$URI1" Reality >/dev/null || fail "add 1"
vless_link_add "$URI2" WS >/dev/null || fail "add 2"
vless_link_add "$URI1" Reality >/dev/null || fail "повтор add"
[ "$(grep -c . "$(_vless_links)")" = 2 ] || fail "дубликат ссылки"
ID1=$(_vless_uri_id "$URI1")
ID2=$(_vless_uri_id "$URI2")
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

# Смена ссылки при включённом VLESS перезапускает только Xray, не движок:
# иначе панель на 443 движка пропадает вместе с ответом на запрос.
VLESS_ENABLED=true
VLESS_ACTIVE=$ID1
_engine_calls=0
: > "$t/restart.log"
vless_link_use "$ID2" >/dev/null || fail "link use при включённом VLESS"
[ "$_engine_calls" = 0 ] || fail "link use перезапустил движок"
grep -q '^restart$' "$t/restart.log" || fail "link use не перезапустил Xray"
grep -q "ExecStart=$INSTALL_DIR/vless/xray run -c $INSTALL_DIR/vless/config.json" "$t/systemd/mtproxyl-vless.service" \
    || fail "unit ссылается не на рабочий каталог"
VLESS_ACTIVE=$ID1
VLESS_ENABLED=false

# Включение: upstream socks5 + локальная замаскировка не нужна.
vless_on >/dev/null || fail "vless_on"
grep -q "add vless socks5 127.0.0.1:$(_vless_port) 1 " "$t/up.log" || fail "upstream не добавлен: $(cat "$t/up.log")"
grep -q '^add vlesslocal' "$t/up.log" && fail "лишний local-маршрут без локальной маскировки"
[ "$VLESS_ENABLED" = true ] || fail "enabled не выставлен"

# Панельный путь: рестарт движка отложен, ответ на запрос успевает уйти.
vless_off >/dev/null || fail "vless_off"
: > "$t/systemd-run.log"; _engine_calls=0
vless_on --defer-restart >/dev/null || fail "vless_on --defer-restart"
[ "$_engine_calls" = 0 ] || fail "defer-restart перезапустил движок синхронно"
grep -q 'vless on' "$t/systemd-run.log" || fail "включение не отложено целиком"
grep -q -- '--on-active=3' "$t/systemd-run.log" || fail "нет задержки применения"

# При включённом WARP: отказ без --yes, выключение с ним.
touch "$t/warp-on"; load_settings
vless_on >/dev/null 2>&1 && fail "конфликт с WARP проигнорирован"
mtdd_mgr_active() { return 0; }
vless_on --yes >/dev/null 2>&1 && fail "переход на Direct без согласия"
[ "$WARP_ENABLED" = true ] || fail "действующий WARP выключен до согласия на Direct"
mtdd_mgr_active() { return 1; }
vless_on --yes >/dev/null 2>&1 || fail "vless on --yes"
grep -q warp-off "$t/conf.log" || fail "WARP не выключен"
vless_off >/dev/null || fail "vless_off после WARP"

# ME с VLESS несовместим: mtdd требует явного согласия.
mtdd_mgr_active() { return 0; }
vless_on >/dev/null 2>&1 && fail "mtdd без согласия на Direct"
vless_on --yes --allow-disable-me >/dev/null 2>&1 || fail "mtdd с согласием"
mtdd_mgr_active() { return 1; }

# Выключение: upstream снят; панельный путь тоже откладывает рестарт.
: > "$t/systemd-run.log"; _engine_calls=0
: > "$t/systemd-run.log"; _engine_calls=0
vless_off --defer-restart >/dev/null || fail "vless_off --defer-restart"
grep -q '^rm vless$' "$t/up.log" || fail "upstream не снят"
[ "$VLESS_ENABLED" = false ] || fail "enabled не снят"
[ "$_engine_calls" = 0 ] || fail "vless_off --defer-restart перезапустил движок"
grep -q 'vless engine-apply' "$t/systemd-run.log" || fail "vless_off: нет отложенного применения"

# Нерабочий Xray не должен отключать действующий выход.
touch "$t/warp-on"; load_settings
_test_online=false
: > "$t/conf.log"
vless_on --yes >/dev/null 2>&1 && fail "нерабочая ссылка VLESS применилась"
[ -f "$t/warp-on" ] && [ ! -s "$t/conf.log" ] || fail "WARP затронут до проверки VLESS"
rm "$t/warp-on"; load_settings
_test_online=true

touch "$t/awg-on"
_test_awg_me_disabled=manager
vless_on --yes >"$t/rollback.log" 2>&1 && fail "снятие AWG восстановит ME без согласия на его выключение"
grep -q -- '--allow-disable-me' "$t/rollback.log" || fail "нет сообщения о согласии на ME при снятии AWG"
rm "$t/awg-on"
_test_awg_me_disabled=""

# Сбой после записи маршрута восстанавливает файлы и возвращает прежний выход.
(
    _test_engine_failure=true
    is_proxy_running() { return 0; }
    _engine_config_path() { echo "$t/config.toml"; }
    handle_expert_command() { echo changed > "$EXPERT_OVERRIDES_FILE"; }
    upstream_add() { echo changed > "$UPSTREAMS_FILE"; }
    echo '[general]' > "$t/config.toml"
    for previous in direct warp donor awg; do
        [ "$previous" = direct ] || touch "$t/$previous-on"
        load_settings
        echo original > "$UPSTREAMS_FILE"
        echo original > "$EXPERT_OVERRIDES_FILE"
        : > "$t/engine.log"; : > "$t/disable.log"
        vless_on --yes --allow-disable-me >"$t/rollback.log" 2>&1 && fail "$previous: ошибка движка потеряна"
        grep -q 'Прежний маршрут восстановлен' "$t/rollback.log" || fail "$previous: нет подтверждения отката"
        [ "$VLESS_ENABLED" = false ] || fail "$previous: VLESS остался включён"
        [ "$(cat "$UPSTREAMS_FILE")" = original ] || fail "$previous: upstream не восстановлен"
        [ "$(cat "$EXPERT_OVERRIDES_FILE")" = original ] || fail "$previous: настройки эксперта не восстановлены"
        grep -q '^false true$' "$t/engine.log" || fail "$previous: движок не запущен после отката"
        grep -q '^disable --now mtproxyl-vless.service$' "$t/disable.log" || fail "$previous: Xray не выключен"
        [ "$previous" = direct ] || rm "$t/$previous-on" || fail "$previous: выход не восстановлен"
    done

    touch "$t/warp-on"; load_settings
    _test_restore_failure=true
    vless_on --yes --allow-disable-me >"$t/rollback.log" 2>&1 && fail "сбой восстановления потерян"
    grep -q 'Откат завершился с ошибкой' "$t/rollback.log" || fail "нет сообщения о неполном откате"
    grep -q 'Не удалось вернуть.*WARP' "$t/rollback.log" || fail "не указан невосстановленный выход"
    [ ! -f "$t/warp-on" ] || fail "тест не имитировал сбой WARP"
) || fail "откат VLESS"

# Чистая установка: при ошибке сохранения удаляются только созданные настройки.
(
    rm -f "$UPSTREAMS_FILE" "$EXPERT_OVERRIDES_FILE"
    save_settings() { [ "$VLESS_ENABLED" != true ]; }
    upstream_add() { echo changed > "$UPSTREAMS_FILE"; }
    vless_on >"$t/rollback.log" 2>&1 && fail "ошибка сохранения VLESS потеряна"
    grep -q 'Прежний маршрут восстановлен' "$t/rollback.log" || fail "откат на чистой установке"
    [ ! -e "$UPSTREAMS_FILE" ] || fail "остался новый маршрут VLESS"
) || fail "откат VLESS после ошибки сохранения"

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
PBK='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
cat > "$t/sub.json" <<JSON
[{"remarks":"JSON node","outbounds":[
 {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"example.org","port":443,"users":[{"id":"77777777-7777-7777-7777-777777777777","encryption":"none"}]}]},"streamSettings":{"network":"xhttp","security":"reality","realitySettings":{"serverName":"example.org","publicKey":"$PBK","shortId":"ab12","fingerprint":"chrome"},"xhttpSettings":{"path":"/xhttp","mode":"auto"}}},
 {"tag":"hy","protocol":"hysteria"},
 {"tag":"block","protocol":"blackhole"}
]}]
JSON
bash "$repo/lib/vless_parse.sh" from-json "$t/sub.json" > "$t/sub.uris" || fail "from-json"
[ "$(grep -c '^vless://' "$t/sub.uris")" = 1 ] || fail "JSON: не один VLESS"
bash "$repo/lib/vless_parse.sh" check "$(cat "$t/sub.uris")" | jq -e '.security=="reality" and .transport=="xhttp" and .name=="JSON node"' >/dev/null || fail "JSON: поля VLESS"
cp "$t/sub.json" "$t/feed.b64"
vless_sub_refresh >/dev/null 2>&1 || fail "JSON-подписка"
[ "$(grep -c '|sub|' "$(_vless_links)")" = 1 ] || fail "JSON-ссылка не импортирована"
vless_sub_off >/dev/null || fail "sub off JSON"
[ "$(grep -c '|sub|' "$(_vless_links)")" = 0 ] || fail "sub-ссылки остались после off"
[ "$(grep -c '|manual|' "$(_vless_links)")" = 2 ] || fail "ручные ссылки удалены вместе с подпиской"
[ ! -e "$(_vless_sub_title_file)" ] || fail "заголовок подписки остался"

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
[ "$(grep -c '|sub|' "$(_vless_links)")" = 0 ] || fail "sub-ссылки остались после off"
[ "$(grep -c '|manual|' "$(_vless_links)")" = 2 ] || fail "ручные ссылки удалены вместе с подпиской"
[ ! -e "$(_vless_sub_notice_file)" ] || fail "сообщение подписки осталось"
vless_status_json | jq -e '(.hwid|length) > 0 and .hwid_enabled == true and (.sub_ua|length) > 0' >/dev/null || fail "status: HWID и UA"
_status_text=$(vless_status)
[[ "$_status_text" == *"VLESS: выключен"* && "$_status_text" == *"SOCKS5: 127.0.0.1:41100"* ]] \
    || fail "status: текст состояния"
# Состояние middle proxy видно в статусе: при VLESS и выключенном ME — disabled.
VLESS_ENABLED=true
_vless_me_enabled() { return 1; }
vless_status_json | jq -e '.me_state == "disabled"' >/dev/null || fail "status: ME выключен"
VLESS_ENABLED=false

# Отказ: первые две проверки — перезапуск, четвёртая — смена ссылки.
VLESS_ENABLED=true
VLESS_ACTIVE=$ID1
: > "$t/restart.log"
systemctl() {
    case "$1" in
        restart) echo restart >> "$t/restart.log" ;;
        is-active) echo active ;;
        *) return 0 ;;
    esac
}
_test_online=false
vless_watch; vless_watch
[ "$(grep -c restart "$t/restart.log")" = 1 ] || fail "перезапуск после двух сбоев"
vless_watch; vless_watch
[ "$VLESS_ACTIVE" != "$ID1" ] || fail "не переключился на запасную ссылку"
_test_online=true

# Массовое удаление: несколько ID одним вызовом, активная не меняется.
URI5='vless://66666666-6666-6666-6666-666666666666@example.org:443?security=tls&sni=example.org&type=tcp#Bulk1'
URI6='vless://77777777-7777-7777-7777-777777777777@example.org:443?security=tls&sni=example.org&type=tcp#Bulk2'
vless_link_add "$URI5" Bulk1 >/dev/null || fail "add Bulk1"
vless_link_add "$URI6" Bulk2 >/dev/null || fail "add Bulk2"
B1=$(_vless_uri_id "$URI5"); B2=$(_vless_uri_id "$URI6")
ACTIVE_BEFORE=$VLESS_ACTIVE
handle_vless_command link remove "$B1" "$B2" >/dev/null || fail "массовое удаление"
[ "$(grep -c '|manual|' "$(_vless_links)")" = 2 ] || fail "массовое удаление задело другие ссылки"
grep -q "|$B1|" "$(_vless_links)" && fail "Bulk1 осталась"
[ "$VLESS_ACTIVE" = "$ACTIVE_BEFORE" ] || fail "массовое удаление сменило активную ссылку"

# Парсер — обычная библиотека из списка, без отдельного Python-файла.
[ -f "$repo/lib/vless_parse.sh" ] || fail "нет lib/vless_parse.sh"
bash -n "$repo/lib/vless_parse.sh" || fail "синтаксис lib/vless_parse.sh"
bash "$repo/lib/vless_parse.sh" check "$URI1" >/dev/null || fail "парсер как CLI"
URI_UDP443="${URI1/flow=xtls-rprx-vision/flow=xtls-rprx-vision-udp443}"
bash "$repo/lib/vless_parse.sh" check "$URI_UDP443" | jq -e '.flow == "xtls-rprx-vision-udp443"' >/dev/null \
    || fail "парсер отбросил Vision UDP/443"

# Служебная команда таймера применяет конфиг сразу, без повторной отсрочки.
_engine_calls=0
handle_vless_command engine-apply >/dev/null || fail "engine-apply"
[ "$_engine_calls" = 1 ] || fail "engine-apply не применил конфиг"

echo "OK vless"
