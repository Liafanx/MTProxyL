#!/bin/bash
# Остаток квоты Globalping: от слов сервиса, иначе по своим тратам.
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
for f in lib/*.sh; do source "$f" >/dev/null 2>&1; done
fail() { printf '%s\n' "$*" >&2; exit 1; }
mkdir -p "$test_dir/availability"
q="$test_dir/availability/quota"
now=$(date +%s)
state() { read -r B S R T X <<< "$(_avail_quota_state)"; }

# Только свои траты.
printf 'SPEND %d 20\nSPEND %d 20\n' $((now-4000)) $((now-100)) > "$q"
state; [ "$B $R" = "250 230" ] || fail "свои траты: $B $R"

# Сервис сказал 40 при наших 230: верим ему, минус траты после замера.
printf 'SPEND %d 20\nREAL %d 250 40 %d\nSPEND %d 20\n' $((now-100)) $((now-50)) $((now+600)) $((now-10)) > "$q"
state; [ "$R" = 20 ] && [ "$T" -ge 598 ] && [ "$T" -le 600 ] || fail "REAL: $R $T"

# Окно сервиса кончилось: траты до его конца прощены.
printf 'SPEND %d 20\nREAL %d 250 0 %d\nSPEND %d 20\n' $((now-3000)) $((now-2900)) $((now-60)) $((now-30)) > "$q"
state; [ "$R" = 230 ] || fail "после окна: $R"

# Блокировка 429 важнее всего.
printf 'REAL %d 250 200 %d\nBLOCK %d\n' $((now-10)) $((now+600)) $((now+300)) > "$q"
state; [ "$R $X" = "0 1" ] && [ "$T" -ge 298 ] && [ "$T" -le 300 ] || fail "BLOCK: $R $T $X"

# Компакт оставляет один, последний REAL.
printf 'REAL %d 250 10 %d\nREAL %d 250 5 %d\n' $((now-20)) $((now+60)) $((now-10)) $((now+60)) > "$q"
_avail_quota_compact
[ "$(grep -c REAL "$q")" = 1 ] && grep -q "250 5 " "$q" || fail "compact: $(cat "$q")"

# Цена расписания.
AVAILABILITY_INTERVAL=15 AVAILABILITY_PROBES=20; [ "$(_avail_schedule_cost)" = 80 ] || fail "15/20"
AVAILABILITY_INTERVAL=7; [ "$(_avail_schedule_cost)" = 180 ] || fail "7/20: $(_avail_schedule_cost)"
AVAILABILITY_INTERVAL=120; [ "$(_avail_schedule_cost)" = 20 ] || fail "120/20"
echo "availability quota: ok"
