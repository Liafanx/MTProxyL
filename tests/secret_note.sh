#!/bin/bash
# Заметка к пользователю: сохраняется, чистится от разделителей, стирается.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"; VERSION=test
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets; do source "$repo/lib/$_lib.sh"; done
SECRETS_FILE="$test_dir/secrets.conf"
reload_proxy_config() { :; }
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }
fail() { echo "FAIL: $*"; exit 1; }

secret_add alice "" true >/dev/null || fail "add"
secret_set_note alice "Иван | тел. 123"$'\n'"оплачено" >/dev/null || fail "set"
[ "$(secret_set_note alice)" = "Иван   тел. 123 оплачено" ] || fail "чистка: $(secret_set_note alice)"
load_secrets
[ "${SECRETS_NOTES[0]}" = "Иван   тел. 123 оплачено" ] || fail "после перечитывания"
[ "${#SECRETS_LABELS[@]}" = 1 ] || fail "строка базы сломалась"
secret_set_note alice "$(printf 'x%.0s' {1..201})" >/dev/null 2>&1 && fail "длинная принята"
secret_set_note alice - >/dev/null || fail "стереть"
[ -z "$(secret_set_note alice)" ] || fail "не стёрлась"
secret_set_note nobody x >/dev/null 2>&1 && fail "чужая метка"
echo "OK secret_note"
