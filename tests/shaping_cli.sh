#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source lib/shaping.sh

log_error() { printf '%s\n' "$*" >&2; }
log_info() { :; }
shaping_apply() {
    local cfg
    cfg=$(cat)
    shaping_validate_config "$cfg" || return 1
    shaping_atomic_json "$SHAPING_FILE" "$cfg"
    printf 'apply\n' >> "$test_dir/actions"
}
shaping_restore() { printf 'restore\n' >> "$test_dir/actions"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

handle_shaping_command set manual --total 900 --ip 9
jq -e '.enabled and .mode == "manual" and .manual_total_mbps == 900 and .manual_ip_mbps == 9' "$SHAPING_FILE" >/dev/null
[ "$(wc -l < "$test_dir/actions")" -eq 1 ] || fail 'manual set not applied once'
handle_shaping_command set manual --total 900 --ip 9
[ "$(tail -n 1 "$test_dir/actions")" = restore ] || fail 'unchanged enabled config not restored'

handle_shaping_command set fixed --channel 1000 --reserve 10 --users 100
jq -e '.mode == "fixed" and .expected_users == 100 and .manual_ip_mbps == 9' "$SHAPING_FILE" >/dev/null
handle_shaping_command set dynamic --users 20 --exempt-profile admin --exempt-profile trusted \
    --exempt-ip 203.0.113.5 --exempt-ip 198.51.100.0/24
jq -e '.mode == "dynamic" and .expected_users == 20 and
    .profile_exempt == ["admin", "trusted"] and
    .ip_exempt == ["198.51.100.0/24", "203.0.113.5"]' "$SHAPING_FILE" >/dev/null
handle_shaping_command exempt add profile guest
handle_shaping_command exempt remove profile admin
handle_shaping_command exempt add ip 192.0.2.1
handle_shaping_command exempt remove ip 203.0.113.5
jq -e '.profile_exempt == ["guest", "trusted"] and
    .ip_exempt == ["192.0.2.1", "198.51.100.0/24"]' "$SHAPING_FILE" >/dev/null

before=$(cat "$SHAPING_FILE")
for args in \
    'set manual --ip 0' \
    'set manual --ip 1.2.3' \
    'set fixed --reserve 91' \
    'set dynamic --users 1' \
    'set dynamic --total 900' \
    'set manual --channel 1000' \
    'set manual --exempt-ip 999.1.1.1' \
    'exempt add profile' \
    'exempt add ip 999.1.1.1'; do
    read -r -a argv <<< "$args"
    if handle_shaping_command "${argv[@]}" >/dev/null 2>&1; then fail "invalid CLI accepted: $args"; fi
done
[ "$(cat "$SHAPING_FILE")" = "$before" ] || fail 'invalid CLI changed config'

handle_shaping_command off
jq -e '.enabled == false and .mode == "dynamic" and .expected_users == 20' "$SHAPING_FILE" >/dev/null
handle_shaping_command exempt add profile admin
jq -e '.enabled == false and .profile_exempt == ["admin", "guest", "trusted"]' "$SHAPING_FILE" >/dev/null
handle_shaping_command set manual --clear-profiles --clear-ips
jq -e '.enabled and .mode == "manual" and .profile_exempt == [] and .ip_exempt == []' "$SHAPING_FILE" >/dev/null
handle_shaping_command help | grep -q 'shaping set'

echo 'shaping CLI tests: ok'
