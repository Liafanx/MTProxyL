#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-web-target.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
mkdir -p "$CONFIG_DIR"
exec </dev/null

# shellcheck source=/dev/null
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets selfmask web expert_catalog expert_mode; do source "$repo/lib/$_lib.sh"; done
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }
web_public_addr() { echo "203.0.113.5:443"; }
target_engine_version() { echo "$TARGET_VER"; }
TARGET_VER=3.5.13

k1=0123456789abcdef0123456789abcdef
k2=fedcba9876543210fedcba9876543210
k3=00112233445566778899aabbccddeeff

MTPROXYL_MODE=reanimator
DETECTED_MODE=local
DETECTED_NETWORK_MODE=host
DETECTED_PORT=443
DETECTED_CONFIG_PATH="$test_dir/telemt.toml"
WEB_DOMAIN=web.example.com
cat > "$DETECTED_CONFIG_PATH" <<TOML
[general]
use_middle_proxy = true

[general.links]
public_host = "proxy.example.com"

[server]
port = 443

[server.api]
listen = "127.0.0.1:9091"

[censorship]
tls_domain = "mask.example.com"

[access.users]
alice = "$k1"
bob = "$k2"
#mtproxyl-off carol = "$k3"
dave = "$k1"
TOML
cp "$DETECTED_CONFIG_PATH" "$test_dir/orig.toml"

# Перебор carrier: основной из списка выпадает, движок ставит его последним.
WEB_CARRIER=websocket
WEB_CARRIERS="websocket-lanes,websocket,https"
[ "$(web_carriers_effective)" = "websocket-lanes,https" ]
[ "$(web_carriers_toml)" = 'carriers = ["websocket-lanes", "https"]' ]
[ "$(web_carriers_chain)" = "websocket-lanes → https → websocket" ]
TARGET_VER=3.5.3
[ -z "$(web_carriers_toml)" ]
[ "$(web_carriers_chain)" = "websocket" ]
TARGET_VER=3.5.13
_validate_web_carriers_setting ""
_validate_web_carriers_setting none
_validate_web_carriers_setting "https,websocket"
fails _validate_web_carriers_setting "https,https"
fails _validate_web_carriers_setting "quic"

# Флаг менеджера к цели не относится: WEB цели — только свой флаг.
WEB_ENABLED=true; WEB_TARGET_ENABLED=false
fails web_is_enabled
mtproto_is_enabled
fails web_is_only_mode
fails web_frontend_is_haproxy
[ "$(web_public_port)" = 443 ]
[ "$(web_faketls_domain)" = mask.example.com ]
[ "$(web_profile_count)" = 2 ]
fails web_layout_is_split

[ -z "$(web_target_problems)" ]
fails web_target_foreign_web

# shared: цель уходит на приватный порт, :443 и ссылки — через nginx.
WEB_TARGET_ENABLED=true; WEB_TARGET_PORT=443
_web_target_write
cfg=$(cat "$DETECTED_CONFIG_PATH")
grep -qF "$WEB_TARGET_BEGIN" <<< "$cfg"
block=$(awk -v b="$WEB_TARGET_BEGIN" -v e="$WEB_TARGET_END" 'index($0,b)==1{f=1} f{print} index($0,e)==1{f=0}' "$DETECTED_CONFIG_PATH")
grep -q '^port = 15443$' <<< "$block"
grep -q '^transport = "web"$' <<< "$block"
grep -q '^carriers = \["websocket-lanes", "https"\]$' <<< "$block"
[ "$(grep -c '^\[\[web.vhosts.profiles\]\]$' <<< "$block")" = 2 ]
grep -q '^user = "alice"$' <<< "$block"
grep -q '^user = "bob"$' <<< "$block"
! grep -q 'carol\|dave' <<< "$block"
[ "$(_toml_get_string_in_section general.links public_port "$DETECTED_CONFIG_PATH")" = 443 ]
grep -q '^proxy_protocol_trusted_cidrs = \["127.0.0.1/32"\]$' "$DETECTED_CONFIG_PATH"
[ "$WEB_TARGET_PREV_PUBLIC_PORT|$WEB_TARGET_PREV_PP_CIDRS" = "__absent__|__absent__" ]
# Порт цели определяется по [server], а не по нашему listener'у.
[ "$(_toml_get_value port "$DETECTED_CONFIG_PATH")" = 443 ]
fails web_target_foreign_web

# Новый пользователь получает профиль вне блока — это не «чужой» WEB.
_target_set_in_section eve "\"$k3\"" access.users
web_target_add_profile eve >/dev/null
web_target_has_profile eve
fails web_target_foreign_web
# Выключенный пользователь теряет профиль: иначе движок не примет конфиг.
backup_target_config() { TARGET_CONFIG_BACKUP=""; }
_target_users_apply() { :; }
target_user_toggle eve disable >/dev/null
fails web_target_has_profile eve
target_user_toggle eve enable >/dev/null
web_target_has_profile eve

# Повторное применение не плодит блоков и помнит исходные значения.
_web_target_write
[ "$(grep -cF "$WEB_TARGET_BEGIN" "$DETECTED_CONFIG_PATH")" = 1 ]
[ "$WEB_TARGET_PREV_PUBLIC_PORT" = "__absent__" ]

# Снятие возвращает конфиг цели к исходному, кроме нового пользователя.
_toml_safe_unset eve access.users "$DETECTED_CONFIG_PATH"
_web_target_strip
_web_target_restore_keys
diff "$test_dir/orig.toml" "$DETECTED_CONFIG_PATH"

# split: цель не на 443 остаётся на своём порту, ссылки не трогаем.
sed -i 's/^port = 443$/port = 8443/' "$DETECTED_CONFIG_PATH"
cp "$DETECTED_CONFIG_PATH" "$test_dir/orig-split.toml"
DETECTED_PORT=8443; WEB_TARGET_PORT=8443
web_layout_is_split
_web_target_write
block=$(awk -v b="$WEB_TARGET_BEGIN" -v e="$WEB_TARGET_END" 'index($0,b)==1{f=1} f{print} index($0,e)==1{f=0}' "$DETECTED_CONFIG_PATH")
grep -q '^ip = "0.0.0.0"$' <<< "$block"
grep -q '^port = 8443$' <<< "$block"
fails grep -q '^port = 15443$' <<< "$block"
fails grep -q 'public_port' "$DETECTED_CONFIG_PATH"
_web_target_strip
_web_target_restore_keys
diff "$test_dir/orig-split.toml" "$DETECTED_CONFIG_PATH"
DETECTED_PORT=443; WEB_TARGET_PORT=443
sed -i 's/^port = 8443$/port = 443/' "$DETECTED_CONFIG_PATH"

# Порт цели читается мимо нашего блока, даже если в [server] его нет.
sed -i '/^port = 443$/d' "$DETECTED_CONFIG_PATH"
cp "$DETECTED_CONFIG_PATH" "$test_dir/orig-noport.toml"
_web_target_write
[ -z "$(_toml_get_value port "$DETECTED_CONFIG_PATH")" ]
# Цель без [server] и [general.links]: таблицы уходят в начало блока, до listener'ов.
grep -v '^\[server\]$\|^\[general.links\]$\|^public_host' "$test_dir/orig-noport.toml" > "$DETECTED_CONFIG_PATH"
cp "$DETECTED_CONFIG_PATH" "$test_dir/orig-bare.toml"
WEB_TARGET_PREV_SAVED=false; WEB_TARGET_PREV_PUBLIC_PORT=""; WEB_TARGET_PREV_PP_CIDRS=""
_web_target_write
block=$(awk -v b="$WEB_TARGET_BEGIN" -v e="$WEB_TARGET_END" 'index($0,b)==1{f=1} f{print} index($0,e)==1{f=0}' "$DETECTED_CONFIG_PATH")
[ "$(grep -n '^\[server\]$' <<< "$block" | cut -d: -f1)" -lt "$(grep -n '^\[\[server.listeners\]\]$' <<< "$block" | head -1 | cut -d: -f1)" ]
grep -q '^\[general.links\]$' <<< "$block"
_web_target_in_copy _web_target_unwrite_now
diff "$test_dir/orig-bare.toml" "$DETECTED_CONFIG_PATH"
cp "$test_dir/orig.toml" "$DETECTED_CONFIG_PATH"
WEB_TARGET_PREV_SAVED=false; WEB_TARGET_PREV_PUBLIC_PORT=""; WEB_TARGET_PREV_PP_CIDRS=""

# Чего MTProxyL у цели не делает.
printf '\n[web]\nenabled = true\n' >> "$DETECTED_CONFIG_PATH"
web_target_foreign_web
[[ "$(web_target_problems)" == *"настроил её хозяин"* ]]
cp "$test_dir/orig.toml" "$DETECTED_CONFIG_PATH"
printf '\n[[server.listeners]]\nip = "0.0.0.0"\nport = 443\n' >> "$DETECTED_CONFIG_PATH"
[[ "$(web_target_problems)" == *"свои [[server.listeners]]"* ]]
cp "$test_dir/orig.toml" "$DETECTED_CONFIG_PATH"
DETECTED_NETWORK_MODE=bridge
[[ "$(web_target_problems)" == *"без сети хоста"* ]]
DETECTED_NETWORK_MODE=host; DETECTED_MODE=docker
[[ "$(web_target_problems)" == *"HTTP-origin"* ]]
DETECTED_MODE=mtproxymax
[[ "$(web_target_problems)" == *"mtproxymax"* ]]
DETECTED_MODE=local
fails web_set_param WEB_FRONTEND haproxy

# Статус для панели: owner и раскладка цели, а не менеджера.
PROXY_MODE=web; WEB_LAYOUT=split
json=$(web_status_json)
WEB_FRONTEND=haproxy
json=$(web_status_json)
jq -e '.owner == "mtproxyl" and .reanimator and .layout == "shared" and .proxy_mode == "combined" and .proxy_port == 443 and .frontend == "nginx"' <<< "$json" >/dev/null
web_settable_json | jq -e 'map(.key) | (index("WEB_FRONTEND") == null) and (index("WEB_CARRIERS") != null)' >/dev/null

# Новые ключи переживают сохранение и загрузку, массив — в кавычках.
for _f in _ensure_availability_timer _ensure_dc_watch_timer _ensure_ip_history_timer _ensure_log_limits _ensure_quiet_timers; do
    eval "$_f() { :; }"
done
WEB_CARRIERS=https,websocket WEB_TARGET_ENABLED=true WEB_TARGET_PORT=443 WEB_TARGET_PREV_SAVED=true
WEB_TARGET_PREV_PUBLIC_PORT=__absent__ WEB_TARGET_PREV_PP_CIDRS='["10.0.0.1/32", "127.0.0.1/32"]'
set +u
save_settings >/dev/null
WEB_CARRIERS=x WEB_TARGET_ENABLED=x WEB_TARGET_PREV_PP_CIDRS=x
load_settings
[ "$WEB_CARRIERS|$WEB_TARGET_ENABLED|$WEB_TARGET_PORT|$WEB_TARGET_PREV_PUBLIC_PORT" = "https,websocket|true|443|__absent__" ]
[ "$WEB_TARGET_PREV_PP_CIDRS" = '["10.0.0.1/32", "127.0.0.1/32"]' ]
set -u

# Битый список из settings.conf не доходит до конфига.
WEB_CARRIERS="https;id"
printf "WEB_CARRIERS='https;id'\n" > "$SETTINGS_FILE"
load_settings
[ -z "$WEB_CARRIERS" ]

echo "web target: ok"
