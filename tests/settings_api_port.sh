#!/bin/bash
# settings list показывает настоящий порт API, а не 9091 по умолчанию.
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
fail() { printf '%s\n' "$*" >&2; exit 1; }

MTPROXYL_MODE=manager; PROXY_API_PORT=9097
out=$(handle_settings_command list --json 2>/dev/null)
[[ "$out" == *'"key":"PROXY_API_PORT"'*'"value":"9097"'* ]] || fail "json: $(grep -o '"key":"PROXY_API_PORT"[^}]*' <<< "$out")"
out=$(handle_settings_command list 2>/dev/null)
grep -qE 'PROXY_API_PORT +9097' <<< "$out" || fail "таблица: $(grep PROXY_API_PORT <<< "$out")"
[ "$PROXY_API_PORT" = 9097 ] || fail "глобальная переменная изменена: $PROXY_API_PORT"
echo "settings api port: ok"
