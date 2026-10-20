#!/bin/bash
# Лимиты и таймауты WEB у цели Reanimator: одна таблица [web.limits],
# таблица хозяина или include не дублируется, оверрайды отдельно от менеджера.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-web-target-limits.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
mkdir -p "$CONFIG_DIR"
exec </dev/null

# shellcheck source=/dev/null
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets selfmask web expert_catalog expert_mode config; do source "$repo/lib/$_lib.sh"; done
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }
check_root() { :; }
web_public_addr() { echo "203.0.113.5:443"; }
target_engine_version() { echo 3.5.14; }

MTPROXYL_MODE=reanimator
DETECTED_MODE=local
DETECTED_NETWORK_MODE=host
DETECTED_PORT=443
DETECTED_CONFIG_PATH="$test_dir/telemt.toml"
WEB_DOMAIN=web.example.com
WEB_TARGET_ENABLED=true; WEB_TARGET_PORT=443

# Цель с N пользователями — у каждого свой секрет, значит и свой профиль.
make_target() {
    local _n="$1" _head="${2:-}" i
    {
        [ -z "$_head" ] || printf '%s\n\n' "$_head"
        printf '[general]\nuse_middle_proxy = true\n\n[server]\nport = 443\n\n'
        printf '[server.api]\nlisten = "127.0.0.1:9091"\n\n[censorship]\ntls_domain = "mask.example.com"\n\n[access.users]\n'
        for ((i = 1; i <= _n; i++)); do printf 'u%d = "%032x"\n' "$i" "$i"; done
    } > "$DETECTED_CONFIG_PATH"
}
limits_tables() { cat "$@" | grep -c '^\[web\.limits\]$' || true; }
block() { awk -v b="$WEB_TARGET_BEGIN" -v e="$WEB_TARGET_END" 'index($0,b)==1{f=1} f{print} index($0,e)==1{f=0}' "$DETECTED_CONFIG_PATH"; }

# Оверрайды менеджера (expert.conf) к цели не относятся.
printf 'web.limits|max_sessions_global|999\n' > "$INSTALL_DIR/expert.conf"
printf 'web.limits|pending_bytes_global|134217728\nweb.timeouts|idle_ms|5000\n' > "$EXPERT_TARGET_OVERRIDES_FILE"

# 1. Своих таблиц у цели нет — всё в нашем блоке, одной таблицей.
make_target 40
_web_target_write
b=$(block)
[ "$(grep -c '^\[web\.limits\]$' <<< "$b")" = 1 ]
grep -q '^max_profiles = 64$' <<< "$b"
grep -q '^pending_bytes_global = 134217728$' <<< "$b"
grep -q '^\[web\.timeouts\]$' <<< "$b"
fails grep -q 'max_sessions_global' "$DETECTED_CONFIG_PATH"
[ "$(_web_target_max_profiles)" = 64 ]

# 2. [web.limits] хозяина вне блока — это не «чужой WEB»: включить можно,
# ключи дописываются в его таблицу, его больший max_profiles не понижается.
make_target 40
printf '\n[web.limits]\nmax_profiles = 128\nmax_vhosts = 4\n' >> "$DETECTED_CONFIG_PATH"
fails web_target_foreign_web
[ -z "$(web_target_problems)" ]
_web_target_write
[ "$(limits_tables "$DETECTED_CONFIG_PATH")" = 1 ]
fails grep -q '^\[web\.limits\]$' <<< "$(block)"
[ "$(_toml_get_string_in_section web.limits max_profiles "$DETECTED_CONFIG_PATH")" = 128 ]
[ "$(_toml_get_string_in_section web.limits pending_bytes_global "$DETECTED_CONFIG_PATH")" = 134217728 ]
[ "$(_toml_get_string_in_section web.limits max_vhosts "$DETECTED_CONFIG_PATH")" = 4 ]
# Повторная пересборка (web enable после disable) не плодит таблиц.
_web_target_write
[ "$(limits_tables "$DETECTED_CONFIG_PATH")" = 1 ]
# Чужие таблицы WEB по-прежнему чужие.
printf '\n[web]\nenabled = true\n' >> "$DETECTED_CONFIG_PATH"
web_target_foreign_web

# 2б. Хозяин дописал свою таблицу уже после включения: в конфиге две, цель
# не поднимется. Починка переносит наши ключи к нему, его значения целы.
make_target 40
_web_target_write
printf '\n[web.limits]\nmax_vhosts = 2\n' >> "$DETECTED_CONFIG_PATH"
[ "$(limits_tables "$DETECTED_CONFIG_PATH")" = 2 ]
[ "$(web_target_dup_tables)" = web.limits ]
web_target_heal_tables >/dev/null 2>&1
[ "$(limits_tables "$DETECTED_CONFIG_PATH")" = 1 ]
[ -z "$(web_target_dup_tables)" ]
[ "$(_toml_get_string_in_section web.limits max_vhosts "$DETECTED_CONFIG_PATH")" = 2 ]
[ "$(_toml_get_string_in_section web.limits max_profiles "$DETECTED_CONFIG_PATH")" = 64 ]
# Без дубля — ничего не трогаем.
cp "$DETECTED_CONFIG_PATH" "$test_dir/before"
web_target_heal_tables >/dev/null 2>&1
cmp -s "$DETECTED_CONFIG_PATH" "$test_dir/before"

# 3. include с [web.limits]: лимит профилей поднимается в нём, а не второй
# таблицей в конфиге (иначе telemt: duplicate key).
make_target 32 'include = "web-limits.toml"'
printf '[web.limits]\npending_bytes_global = 268435456\n' > "$test_dir/web-limits.toml"
[ "$(_web_target_includes)" = "$test_dir/web-limits.toml" ]
_web_target_write
[ "$(limits_tables "$DETECTED_CONFIG_PATH")" = 0 ]
[ "$(limits_tables "$test_dir/web-limits.toml")" = 1 ]
# 33-й пользователь — max_profiles растёт в include.
printf 'u33 = "%032x"\n' 33 > "$test_dir/u33"
sed -i "/^u32 = /r $test_dir/u33" "$DETECTED_CONFIG_PATH"
web_target_add_profile u33 >/dev/null
[ "$(limits_tables "$DETECTED_CONFIG_PATH")" = 0 ]
[ "$(limits_tables "$test_dir/web-limits.toml")" = 1 ]
[ "$(_toml_get_string_in_section web.limits max_profiles "$test_dir/web-limits.toml")" = 64 ]
[ "$(_toml_get_string_in_section web.limits pending_bytes_global "$test_dir/web-limits.toml")" = 134217728 ]
[ "$(_web_target_max_profiles)" = 64 ]

# 4. expert в реаниматоре: только web.limits и web.timeouts, в свой файл.
fails handle_expert_command set general use_middle_proxy false --no-apply
fails handle_expert_command edit
handle_expert_command set web.limits max_sessions_global 32 --no-apply >/dev/null
grep -qx 'web.limits|max_sessions_global|32' "$EXPERT_TARGET_OVERRIDES_FILE"
grep -qx 'web.limits|max_sessions_global|999' "$INSTALL_DIR/expert.conf"
handle_expert_command preset web-small --no-apply >/dev/null
grep -qx 'web.limits|memory_envelope_bytes|671088640' "$EXPERT_TARGET_OVERRIDES_FILE"
handle_expert_command preset web-reset --no-apply >/dev/null
fails grep -q 'memory_envelope_bytes' "$EXPERT_TARGET_OVERRIDES_FILE"
handle_expert_command clear web.limits max_sessions_global --no-apply >/dev/null
fails grep -q 'max_sessions_global' "$EXPERT_TARGET_OVERRIDES_FILE"

# 5. Лимиты, которые движок не примет: правка откатывается.
make_target 4
fails handle_expert_command set web.limits memory_envelope_bytes 268435456 --no-apply
fails grep -q 'memory_envelope_bytes' "$EXPERT_TARGET_OVERRIDES_FILE"
fails handle_expert_command set web.limits pending_bytes_per_session 999999999 --no-apply
handle_expert_command preset web-small --no-apply >/dev/null 2>&1
[ -z "$(web_limits_check)" ]
# Снять envelope при урезанном остальном можно (умолчание 1280 МиБ вмещает),
# а поднять pending_bytes_global выше envelope пресета — нет.
fails handle_expert_command set web.limits pending_bytes_global 805306368 --no-apply
grep -qx 'web.limits|pending_bytes_global|134217728' "$EXPERT_TARGET_OVERRIDES_FILE"
handle_expert_command preset web-reset --no-apply >/dev/null 2>&1
# Таблица хозяина тоже учитывается.
printf '\n[web.limits]\nmemory_envelope_bytes = 268_435_456\n' >> "$DETECTED_CONFIG_PATH"
web_limits_check | grep -q 'memory_envelope_bytes 256 МиБ'

echo "web target limits: ok"
