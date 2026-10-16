#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source lib/shaping.sh
log_error() { printf '%s\n' "$*" >&2; }
shaping_status_json() { jq -nc --argjson config "$(shaping_config)" '{config:$config,state:{active_ips:0},rates:{ip_bps:90000000}}'; }
shaping_apply() {
    local cfg
    cfg=$(cat)
    shaping_validate_config "$cfg"
    shaping_atomic_json "$SHAPING_FILE" "$cfg"
}

# Пустые и неверные числа повторно запрашиваются до формирования JSON.
printf '3\n\nabc\n0\n100001\n1000\n91\n\n1\n20\n\n\n' | shaping_menu >"$test_dir/out" 2>"$test_dir/err"
jq -e '.enabled and .mode=="dynamic" and .channel_mbps==1000 and .reserve_percent==10 and .expected_users==20' "$SHAPING_FILE" >/dev/null
grep -q 'Обязательное поле' "$test_dir/err"
! grep -q 'jq:' "$test_dir/err"

printf '1\n\n900\n\n0\nword\n901\n0.1\n\n\n' | shaping_menu >"$test_dir/out" 2>"$test_dir/err"
jq -e '.mode=="manual" and .manual_total_mbps==900 and .manual_ip_mbps==0.1' "$SHAPING_FILE" >/dev/null
grep -q 'не может превышать' "$test_dir/err"
! grep -q 'jq:' "$test_dir/err"

printf '2\n1000\n0\n\n\n\n' | shaping_menu >"$test_dir/out" 2>"$test_dir/err"
jq -e '.mode=="fixed" and .reserve_percent==0 and .expected_users==10' "$SHAPING_FILE" >/dev/null

before=$(cat "$SHAPING_FILE")
for input in '3\n' '1\n900\n' '2\n1000\n10\n20\n'; do
    if printf '%b' "$input" | shaping_menu >"$test_dir/out" 2>"$test_dir/err"; then
        echo 'EOF accepted as a complete configuration' >&2; exit 1
    fi
    [ "$(cat "$SHAPING_FILE")" = "$before" ]
    ! grep -q 'jq:' "$test_dir/err"
done
echo 'shaping menu tests: ok'
