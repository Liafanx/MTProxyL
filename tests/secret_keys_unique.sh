#!/bin/bash
# Один ключ — один пользователь: в менеджере и у цели реаниматора.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"; VERSION=test
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets; do source "$repo/lib/$_lib.sh"; done
SECRETS_FILE="$test_dir/secrets.conf"
backup_target_config() { TARGET_CONFIG_BACKUP=""; }
_target_users_apply() { :; }
web_target_add_profile() { :; }
reload_proxy_config() { :; }
restart_proxy_container() { :; }
is_proxy_running() { return 1; }
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }
fail() { echo "FAIL: $*"; exit 1; }
k1=0123456789abcdef0123456789abcdef
k2=fedcba9876543210fedcba9876543210

secret_add alice "$k1" true >/dev/null || fail "первый ключ"
secret_add bob "${k1^^}" true >/dev/null 2>&1 && fail "тот же ключ в другом регистре принят"
secret_add bob "$k2" true >/dev/null || fail "другой ключ"
secret_rotate bob "$k1" >/dev/null 2>&1 && fail "rotate на чужой ключ принят"
secret_rotate bob "$k2" >/dev/null 2>&1 || fail "rotate на свой же ключ"
[ "$(_secret_key_owner "$k2")" = bob ] || fail "владелец ключа"
_secret_key_owner "$k2" 1 >/dev/null && fail "свой индекс не исключён"

printf 'carol|%s|0|true|0|0|0|0||||\ndave|%s|0|true|0|0|0|0||||\n' "$k1" \
    00112233445566778899aabbccddeeff > "$test_dir/imp.txt"
secret_import_file "$test_dir/imp.txt" >/dev/null 2>&1
printf '%s\n' "${SECRETS_LABELS[@]}" | grep -qx carol && fail "импорт с чужим ключом"
printf '%s\n' "${SECRETS_LABELS[@]}" | grep -qx dave || fail "импорт с новым ключом"

DETECTED_CONFIG_PATH="$test_dir/target.toml"
printf '[access.users]\nalice = "%s"\n' "$k1" > "$DETECTED_CONFIG_PATH"
_target_users_ready() { return 0; }
target_user_add eve "$k1" >/dev/null 2>&1 && fail "цель: тот же ключ принят"
[ "$(_target_key_owner "${k1^^}")" = alice ] || fail "цель: владелец ключа"
echo "OK secret_keys_unique"
