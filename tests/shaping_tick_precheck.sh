#!/bin/bash
# Предпроверка тика: MTProxyL запускается, только когда активные IP или
# настройки изменились, рост лимита ждёт подтверждения или прошло 5 минут.
set -u
cd "$(dirname "$0")/.." || exit 1
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
INSTALL_DIR="$d"
source lib/shaping.sh
SHAPING_TICK_SCRIPT="$d/tick.sh"; SHAPING_TICK_ENDPOINT="$d/ep"; SHAPING_TICK_SUM="$d/sum"
SHAPING_TICK_MTPROXYL="$d/mtproxyl"
mkdir -p "$d/bin"
cat > "$d/bin/curl" <<'C'
#!/bin/sh
cat "$RESP"
C
cat > "$d/mtproxyl" <<'M'
#!/bin/sh
echo full >> "$LOG"
M
chmod +x "$d/bin/curl" "$d/mtproxyl"
shaping_write_tick_script
export RESP="$d/resp" LOG="$d/log" PATH="$d/bin:$PATH"
echo '{"ok":true,"data":[{"username":"a","active_ips":["192.0.2.1"]}]}' > "$RESP"
echo '{}' > "$d/shaping.json"; touch -d '-1 min' "$d/shaping.json"
echo '{"pending_ips":null}' > "$d/shaping-state.json"
fail=0
run() { : > "$LOG"; sh "$SHAPING_TICK_SCRIPT"; [ -s "$LOG" ] && echo full || echo skip; }
check() { local got; got=$(run); [ "$got" = "$2" ] && echo "OK $1" || { echo "FAIL $1: $got, ждали $2"; fail=1; }; }

check "нет отпечатка" full
printf 'http://127.0.0.1:9091/v1/stats/users/active-ips\n\n' > "$SHAPING_TICK_ENDPOINT"
printf '%s' "$(cat "$RESP")" | cksum > "$SHAPING_TICK_SUM"
check "те же IP" skip
echo '{"ok":true,"data":[{"username":"a","active_ips":["192.0.2.2"]}]}' > "$RESP"
check "новые IP" full
printf '%s' "$(cat "$RESP")" | cksum > "$SHAPING_TICK_SUM"
echo '{"pending_ips":3}' > "$d/shaping-state.json"
check "рост лимита ждёт подтверждения" full
echo '{"pending_ips":null}' > "$d/shaping-state.json"
touch "$d/shaping.json"; touch -d '-1 min' "$SHAPING_TICK_SUM"
check "изменились настройки" full
touch -d '-10 min' "$d/shaping.json"; touch -d '-6 min' "$SHAPING_TICK_SUM"
check "прошло 5 минут" full
exit "$fail"
