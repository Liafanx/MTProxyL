#!/bin/bash
# Отпечаток iOS в mtproto.lua и замена скрипта прошлой версии при обновлении.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
INSTALL_DIR=/opt/mtproxyl
set +u; source "$ROOT/lib/nft.sh"; set -u
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ZAPRET2_LUA="$tmp/mtproto.lua"
restarts=0
systemctl() { [ "$1" = restart ] && restarts=$((restarts + 1)); return 0; }

zapret2_write_lua "$tmp/new.lua"
grep -qF 'if n == 8 and o[8].kind == 0 then n = 7 end' "$tmp/new.lua" || { echo "нет учёта EOL"; exit 1; }
grep -qF 'n == 7 and' "$tmp/new.lua" || { echo "нет проверки 7 опций"; exit 1; }
! grep -qF 'options[8].kind' "$tmp/new.lua" || { echo "старый шаблон"; exit 1; }

# Скрипт прошлой версии — переписываем и перезапускаем.
sed 's/n == 7 and/#desync.dis.tcp.options == 8 and/' "$tmp/new.lua" > "$ZAPRET2_LUA"
zapret2_refresh_lua
cmp -s "$tmp/new.lua" "$ZAPRET2_LUA" || { echo "Lua не обновлён"; exit 1; }
[ "$restarts" -eq 1 ] || { echo "перезапусков: $restarts"; exit 1; }

# Актуальный — не трогаем.
zapret2_refresh_lua
[ "$restarts" -eq 1 ] || { echo "лишний перезапуск"; exit 1; }
echo OK
