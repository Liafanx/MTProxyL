#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
mkdir -p "$INSTALL_DIR/warp"
source "$repo/lib/utils.sh"
source "$repo/lib/warp.sh"
log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { :; }
WARP_MODE=upstream WARP_PROTO=awg WARP_LOCATION='' WARP_ENDPOINT=''
[[ "$(_warp_mtu)" == 1280 ]]
[[ "$(_warp_active_mtu)" == null ]]
save_settings() { printf '%s' "$WARP_MTU" > "$test_dir/saved"; }
_warp_scan_reexclude() { :; }
for value in '' 0 -1 999 1501 1280.5 invalid '1280;id'; do
    if _warp_dispatch mtu "$value" > /dev/null 2>&1; then echo "Accepted invalid MTU: $value"; exit 1; fi
done
[[ ! -e "$test_dir/saved" ]]
WARP_EXCLUDE=DME
if warp_set_settings wg clear clear none 999 >/dev/null 2>&1; then exit 1; fi
[[ "$WARP_EXCLUDE" == DME && "$WARP_PROTO" == awg ]]
_warp_dispatch mtu 1400 >/dev/null
[[ "$(cat "$test_dir/saved")" == 1400 && "$(_warp_mtu)" == 1400 ]]
_warp_write_state '188.114.98.58:2408'
[[ "$(_warp_active_mtu)" == 1400 ]]

# A/C runner must use the applied state, even after another value is saved.
cat > "$(_warp_bin)" <<'BIN'
#!/bin/bash
if [[ "${2:-}" == -h ]]; then echo '-tunnel-mtu N'; exit 0; fi
printf '%s\n' "$@"
BIN
chmod 700 "$(_warp_bin)"
WARP_MTU=1200
_warp_write_socks_runner
bash "$(_warp_runner)" > "$test_dir/args"
[[ "$(tail -n 2 "$test_dir/args" | tr '\n' ' ')" == '-tunnel-mtu 1400 ' ]]
for WARP_MODE in socks upstream; do
    _warp_write_socks_runner
    bash "$(_warp_runner)" | tail -n2 | diff - <(printf '%s\n' -tunnel-mtu 1400)
done

# Legacy warpscout can keep the default, but cannot silently ignore another MTU.
cat > "$(_warp_bin)" <<'BIN'
#!/bin/bash
if [[ "${2:-}" == -h ]]; then echo '-port N'; exit 0; fi
printf '%s\n' "$@"
BIN
if _warp_write_socks_runner >/dev/null 2>&1; then exit 1; fi
jq 'del(.mtu)' "$(_warp_state)" > "$test_dir/legacy"
mv "$test_dir/legacy" "$(_warp_state)"
_warp_write_socks_runner
if bash "$(_warp_runner)" | grep -q -- '-tunnel-mtu'; then exit 1; fi
[[ "$(_warp_active_mtu)" == 1280 ]]

# B writes the requested MTU into the config consumed by wg-quick.
WARP_MODE=iface WARP_MTU=1380
jq -nc '{private_key:("A"*43+"="),peer_public_key:("B"*43+"="),ipv4:"172.16.0.2"}' > "$(_warp_account)"
_warp_generate_iface_conf '188.114.98.58:2408' >/dev/null
grep -qx 'MTU = 1380' "$(_warp_conf)"
_warp_write_state '188.114.98.58:2408'

# A failed apply restores the old runtime MTU; watchdog ignores unapplied settings.
WARP_ENABLED=true WARP_MTU=1400
_warp_start_services() { _warp_active_mtu >> "$test_dir/starts"; }
_warp_wait_route() { return 1; }
if _warp_activate_endpoint '188.114.98.59:2408' >/dev/null 2>&1; then exit 1; fi
[[ "$(_warp_active_mtu)" == 1380 ]]
grep -qx 'MTU = 1380' "$(_warp_conf)"
diff "$test_dir/starts" <(printf '1400\n1380\n')
_warp_wait_route() { return 0; }
# Before MTU entered state.json, B already allowed it through settings.conf.
jq 'del(.mtu)' "$(_warp_state)" > "$test_dir/legacy"
mv "$test_dir/legacy" "$(_warp_state)"
[[ "$(_warp_active_mtu)" == 1380 ]]
mv "$(_warp_conf)" "$test_dir/old.conf"
[[ "$(_warp_active_mtu)" == 1280 ]]
mv "$test_dir/old.conf" "$(_warp_conf)"
_warp_start_services() { [[ "$WARP_MTU" == 1380 ]]; }
warp_recover >/dev/null
[[ "$WARP_MTU" == 1400 ]]

# Status includes both saved and applied MTU, without requiring a running tunnel.
warp_exit_info() { return 1; }
_warp_unit_active() { return 1; }
_warp_nft_applied() { return 1; }
warp_matched_packets() { echo 0; }
ip() { return 1; }
touch "$(_warp_cidr)"
warp_status_json | jq -e '.mtu == 1400 and .active_mtu == 1380' >/dev/null
echo 'warp MTU: ok'
