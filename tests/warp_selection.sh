#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
mkdir -p "$INSTALL_DIR/warp"
source "$repo/lib/utils.sh"
source "$repo/lib/warp.sh"

WARP_MODE=upstream
WARP_PROTO=awg
WARP_LOCATION=SE
WARP_ENDPOINT=""
mapfile -t quick < <(_warp_scan_args quick)
mapfile -t deep < <(_warp_scan_args deep)
[[ " ${quick[*]} " == *" -sample 2 "* ]]
[[ " ${quick[*]} " == *" -tun-ping-count 5 "* ]]
[[ " ${deep[*]} " == *" -sample 5 "* ]]
[[ " ${deep[*]} " == *" -sweep-ports open "* ]]

jq -nc '{status:"success",proto:"awg",filter:"SE",best_endpoint:"8.6.112.130:1701",
    nodes:[{node:"ARN",endpoint:"8.6.112.130:1701",region:"AE",location:"Stockholm, SE"}]}' \
    > "$(_warp_scan_file)"
[[ "$(_warp_cached_endpoint)" == "8.6.112.130:1701" ]]
_warp_exit_matches_location AE ARN
if _warp_exit_matches_location AE DME; then exit 1; fi

# warpscout -country filters the node's country, not Cloudflare trace's loc.
WARP_LOCATION=AE
if _warp_cached_endpoint >/dev/null; then exit 1; fi
if _warp_exit_matches_location AE ARN; then exit 1; fi

WARP_LOCATION=SE
_warp_write_state "8.6.112.130:1701"
[[ $(jq -r '.node + ":" + .country' "$(_warp_state)") == ARN:SE ]]
mv "$(_warp_scan_file)" "$test_dir/old-scan.json"
WARP_MODE=iface
[[ "$(_warp_cached_endpoint)" == "8.6.112.130:1701" ]]
_warp_exit_matches_location AE ARN
jq 'del(.country)' "$(_warp_state)" > "$test_dir/legacy-state.json"
mv "$test_dir/legacy-state.json" "$(_warp_state)"
if _warp_cached_endpoint >/dev/null; then exit 1; fi

# MASQUE has fixed anycast endpoints: a saved location must not hide its scan.
WARP_MODE=upstream
WARP_PROTO=masque
WARP_LOCATION=ARN
jq -nc '{status:"success",proto:"masque",filter:"",best_endpoint:"162.159.198.1:443",
    nodes:[{node:"DME",endpoint:"162.159.198.1:443",region:"AE",location:"Dubai, AE"}]}' \
    > "$(_warp_scan_file)"
[[ "$(_warp_cached_endpoint)" == "162.159.198.1:443" ]]
mapfile -t masque < <(_warp_scan_args deep)
[[ " ${masque[*]} " != *" -sweep-ports "* ]]

# A tunnel responding to Cloudflare is insufficient: probe a Telegram DC.
WARP_MODE=upstream
curl() { printf '* SOCKS5 request granted.\n' >&2; return 28; }
_warp_telegram_probe
WARP_MODE=iface
printf '0\n' > "$test_dir/packet-count"
warp_matched_packets() {
    local count
    count=$(<"$test_dir/packet-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$test_dir/packet-count"
    printf '%s\n' "$count"
}
curl() {
    local uri="${*: -1}" ip
    ip="${uri#telnet://}"
    ip="${ip%:443}"
    printf '* Connected to %s (%s) port 443\n' "$ip" "$ip" >&2
    return 28
}
_warp_telegram_probe
curl() { return 28; }
if _warp_telegram_probe; then exit 1; fi

echo 'warp selection: ok'
