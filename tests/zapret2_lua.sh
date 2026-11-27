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

if zapret2_validate_v2 300 300 || zapret2_validate_v2 300 0 || zapret2_validate_v2 1401 100; then
    echo "неверные параметры v2 приняты"
    exit 1
fi
zapret2_validate_v2 300 100

ZAPRET2_PROFILE=v2 ZAPRET2_V2_WIN=300 ZAPRET2_V2_LEN=100
zapret2_write_lua "$tmp/v2.lua"
grep -qFx 'local win, len, release_at = 300, 100, 1400' "$tmp/v2.lua"

if command -v lua >/dev/null; then
    lua - "$tmp/v2.lua" <<'LUA'
TH_FIN, TH_SYN, TH_RST, TH_ACK = 1, 2, 4, 16
VERDICT_PASS, VERDICT_MODIFY, VERDICT_DROP = 0, 1, 2
function bitand(n, mask)
    local result, bit = 0, 1
    while mask > 0 do
        if n % 2 == 1 and mask % 2 == 1 then result = result + bit end
        n, mask, bit = math.floor(n / 2), math.floor(mask / 2), bit * 2
    end
    return result
end
local window, cutoff, sent, fail = {}, false, {}, false
function wsize_rewrite(_, options) window = options end
function instance_cutoff(_, direction) assert(direction == nil); cutoff = true end
function rawsend_payload_segmented(desync, bytes, offset)
    sent[#sent + 1] = {bytes, offset or 0, desync.arg.badsum}
    return not (fail and desync.arg.badsum)
end
dofile(arg[1])
local state = {}
local initial = 4294967200
local function packet(outgoing, flags, offset, data)
    local seq = (initial + offset) % 4294967296
    local p = {
        outgoing = outgoing, track = {lua_state = state}, arg = {},
        dis = {payload = data or "", tcp = {th_seq = seq, th_ack = seq, th_flags = flags}}
    }
    local verdict = lets_resend({}, p)
    assert(p.arg.badsum == nil)
    return verdict
end
assert(packet(true, TH_SYN + TH_ACK, 0) == VERDICT_MODIFY)
assert(window.wsize == 300 and window.scale == 0)
local a, b, c = ("a"):rep(100), ("b"):rep(100), ("c"):rep(100)
assert(packet(false, TH_ACK, 0, a .. b .. c) == VERDICT_DROP)
assert(sent[1][1] == a and sent[1][2] == 0 and not sent[1][3])
assert(sent[2][1] == c and sent[2][2] == 200 and not sent[2][3])
assert(sent[3][1] == b and sent[3][2] == 100 and sent[3][3])
assert(packet(false, TH_ACK, 100, b) == VERDICT_PASS and #sent == 3)
assert(packet(true, TH_ACK, 300) == VERDICT_MODIFY)
assert(window.wsize == 300 and window.scale == nil)
assert(packet(false, TH_ACK, 300, a .. b) == VERDICT_DROP and #sent == 5)
fail = true
assert(packet(false, TH_ACK, 500, a .. b .. c) == VERDICT_PASS)
assert(state.broken_upto == 500)
assert(packet(true, TH_ACK, 1400) == VERDICT_PASS and cutoff)
assert(packet(false, TH_ACK, 1400, a .. b) == VERDICT_PASS)
LUA
fi

ZAPRET2_PROFILE=v1
ZAPRET2_APPLIED=true
ZAPRET2_LUA_DIR="$tmp"
ZAPRET2_CONF="$tmp/mtproto.conf"
ZAPRET2_OUT_RANGE=p4 ZAPRET2_IN_RANGE=p5
zapret2_write_instance_conf 0 443
zapret2_write_instance_conf 1 443
cp "$ZAPRET2_LUA" "$tmp/original.lua"
cp "$ZAPRET2_CONF" "$tmp/original.conf"
ZAPRET2_BIN=check_conf
check_conf() {
    grep -qxF -- '--dry-run' "${1#@}" || return 1
    local out=$ZAPRET2_OUT_RANGE
    [ "$ZAPRET2_PROFILE" != v2 ] || out=a
    grep -qxF -- "--out-range=$out" "${1#@}"
}
save_nft_settings() { printf '%s\n' "$ZAPRET2_PROFILE" > "$tmp/profile"; }
systemctl() {
    if [ "$1" = restart ] && grep -qF -- 'fix v2' "$ZAPRET2_LUA"; then return 1; fi
    return 0
}
sleep() { :; }
if zapret2_set_profile v2 300 100; then echo "перезапуск должен завершиться ошибкой"; exit 1; fi
[ ! -e "$tmp/profile" ]
cmp -s "$tmp/original.lua" "$ZAPRET2_LUA"
cmp -s "$tmp/original.conf" "$ZAPRET2_CONF"
grep -qxF -- '--in-range=p5' "$tmp/mtproto-1.conf"

systemctl() { return 0; }
zapret2_set_profile v2 300 100
grep -qxF v2 "$tmp/profile"
cmp -s "$tmp/v2.lua" "$ZAPRET2_LUA"
grep -qxF -- '--in-range=a' "$tmp/mtproto-1.conf"

ZAPRET2_PROFILE=v2
zapret2_set_profile v2 420 140
grep -qxF 'local win, len, release_at = 420, 140, 1400' "$ZAPRET2_LUA"
zapret2_set_profile v1 420 140
cmp -s "$tmp/original.lua" "$ZAPRET2_LUA"
cmp -s "$tmp/original.conf" "$ZAPRET2_CONF"
grep -qxF -- '--in-range=p5' "$tmp/mtproto-1.conf"
echo OK
