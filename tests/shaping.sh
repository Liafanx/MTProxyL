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

fixed=$(printf '%s\n' "$cfg" | jq '.enabled=true | .mode="fixed" | .expected_users=20')
[ "$(shaping_rates "$fixed" 2 | jq -r '.profile_bps')" = 45000000 ]
dynamic=$(printf '%s\n' "$fixed" | jq '.mode="dynamic" | .expected_users=10')
[ "$(shaping_rates "$dynamic" 20 | jq -r '.profile_bps')" = 45000000 ]
[ "$(shaping_rates "$dynamic" 1 | jq -r '.profile_bps')" = 90000000 ]

_get_telemt_auth_header() { :; }
engine_config_path() { echo /dev/null; }
curl() {
    printf '%s\n' '{"ok":true,"data":[{"username":"alice","active_ips":["203.0.113.1","203.0.113.1"]},{"username":"bob","active_ips":["203.0.113.2","203.0.113.1"]}]}'
}
[ "$(shaping_fetch_active_ips)" = 2 ] || { echo 'connections/IP dedup failed' >&2; exit 1; }

dynamic=$(printf '%s\n' "$dynamic" | jq '.expected_users=2')
shaping_atomic_json "$SHAPING_FILE" "$dynamic"
shaping_atomic_json "$SHAPING_STATE_FILE" '{"active_ips":2,"last_update_epoch":0}'
curl() {
    printf '%s\n' '{"ok":true,"data":[{"username":"alice","active_ips":["203.0.113.1","203.0.113.2","203.0.113.3"]}]}'
}
shaping_reload_telemt() { echo reload >> "$test_dir/reloads"; }
shaping_tick
[ "$(jq -r '.active_ips' "$SHAPING_STATE_FILE")" = 3 ]
[ "$(wc -l < "$test_dir/reloads")" = 1 ]
curl() { return 7; }
if shaping_tick; then echo 'API outage accepted as a fresh sample' >&2; exit 1; fi
[ "$(jq -r '.active_ips' "$SHAPING_STATE_FILE")" = 3 ]

shaping_atomic_json "$SHAPING_FILE" "$(printf '%s\n' "$fixed" | jq '.profile_exempt=["bob"]')"
SECRETS_LABELS=(alice bob)
SECRETS_ENABLED=(true true)
output="$test_dir/config.toml"
shaping_emit_user_limits "$output"
grep -q 'alice = { up_bps = 0, down_bps = 45000000 }' "$output"
if grep -q '^bob =' "$output"; then echo 'profile exemption ignored' >&2; exit 1; fi
shaping_rename_profile bob robert
[ "$(jq -r '.profile_exempt[0]' "$SHAPING_FILE")" = robert ]

echo 'shaping tests: ok'
