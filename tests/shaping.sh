#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source lib/shaping.sh

cfg=$(shaping_default_config)
shaping_validate_config "$cfg"
bad=$(printf '%s\n' "$cfg" | jq '.ip_exempt=["256.1.1.1"]')
if shaping_validate_config "$bad"; then echo 'invalid IPv4 accepted' >&2; exit 1; fi
bad=$(printf '%s\n' "$cfg" | jq '.expected_users=1')
if shaping_validate_config "$bad"; then echo 'unsafe minimum accepted' >&2; exit 1; fi
shaping_validate_config "$(printf '%s\n' "$cfg" | jq '.profile_exempt=["team.alpha"]')"

fixed=$(printf '%s\n' "$cfg" | jq '.enabled=true | .mode="fixed" | .expected_users=20')
[ "$(shaping_rates "$fixed" 2 | jq -r '.ip_bps')" = 45000000 ]
dynamic=$(printf '%s\n' "$fixed" | jq '.mode="dynamic" | .expected_users=10')
[ "$(shaping_rates "$dynamic" 20 | jq -r '.ip_bps')" = 45000000 ]
[ "$(shaping_rates "$dynamic" 1 | jq -r '.ip_bps')" = 90000000 ]
example=$(printf '%s\n' "$fixed" | jq '.expected_users=100')
[ "$(shaping_rates "$example" 100 | jq -r '.ip_bps')" = 9000000 ]
shaping_atomic_json "$SHAPING_FILE" "$(printf '%s\n' "$cfg" | jq '.manual_profile_mbps=.manual_ip_mbps | del(.manual_ip_mbps)')"
[ "$(shaping_config | jq -r '.manual_ip_mbps')" = 90 ]

_get_telemt_auth_header() { :; }
engine_config_path() { echo /dev/null; }
curl() {
    printf '%s\n' '{"ok":true,"data":[{"username":"alice","active_ips":["203.0.113.1","203.0.113.1"]},{"username":"bob","active_ips":["203.0.113.2","203.0.113.1"]}]}'
}
map=$(shaping_fetch_active_map "$cfg")
[ "$(printf '%s\n' "$map" | jq 'length')" = 2 ] || { echo 'connections/IP dedup failed' >&2; exit 1; }
[ "$(printf '%s\n' "$map" | jq -r '.[0].exempt')" = false ]
exempt_cfg=$(printf '%s\n' "$cfg" | jq '.profile_exempt=["alice"]')
[ "$(shaping_fetch_active_map "$exempt_cfg" | jq -r '.[] | select(.ip == "203.0.113.1") | .exempt')" = false ]
[ "$(shaping_fetch_active_map "$exempt_cfg" | jq -r '.[] | select(.ip == "203.0.113.2") | .exempt')" = false ]
curl() {
    jq -nc '{ok:true,data:[{username:"one_profile",active_ips:[range(1;101) | "198.51.100.\(.)"]}]}'
}
hundred=$(shaping_fetch_active_map "$example")
[ "$(printf '%s\n' "$hundred" | jq 'length')" = 100 ]
[ "$(shaping_rates "$example" "$(printf '%s\n' "$hundred" | jq 'length')" | jq -r '.ip_bps')" = 9000000 ]
entries=$(shaping_assign_ips "$map" '{}' | jq -sc '.')
[ "$(printf '%s\n' "$entries" | jq -r '.[0].minor')" = 256 ]
[ "$(shaping_assign_ips "$map" "$(jq -nc --argjson ips "$entries" '{ips:$ips}')" | jq -sc '.[0].minor')" = 256 ]

dynamic=$(printf '%s\n' "$dynamic" | jq '.expected_users=2')
shaping_atomic_json "$SHAPING_FILE" "$dynamic"
shaping_atomic_json "$SHAPING_STATE_FILE" '{"active_ips":2,"last_update_epoch":0}'
shaping_atomic_json "$SHAPING_TC_FILE" '{"rate_bps":450000000,"ips":[]}'
curl() {
    printf '%s\n' '{"ok":true,"data":[{"username":"alice","active_ips":["203.0.113.1","203.0.113.2","203.0.113.3"]}]}'
}
shaping_tc_sync() { printf '%s\n' "$3" >> "$test_dir/rates"; }
shaping_tick
[ "$(jq -r '.active_ips' "$SHAPING_STATE_FILE")" = 3 ]
[ "$(tail -1 "$test_dir/rates")" = 300000000 ]
curl() { return 7; }
if shaping_tick; then echo 'API outage accepted as a fresh sample' >&2; exit 1; fi
[ "$(jq -r '.active_ips' "$SHAPING_STATE_FILE")" = 3 ]

shaping_atomic_json "$SHAPING_FILE" "$(printf '%s\n' "$fixed" | jq '.profile_exempt=["bob"]')"
shaping_rename_profile bob robert
[ "$(jq -r '.profile_exempt[0]' "$SHAPING_FILE")" = robert ]

echo 'shaping tests: ok'
