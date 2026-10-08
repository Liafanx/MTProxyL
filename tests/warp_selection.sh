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

# A tunnel responding to Cloudflare is insufficient: a DC must answer HTTP.
WARP_MODE=upstream
curl() { printf '404'; }
_warp_telegram_probe
# DME: TCP opens, data is cut — curl reports 000.
curl() { printf '000'; return 28; }
if _warp_telegram_probe; then exit 1; fi
WARP_MODE=iface
printf '0\n' > "$test_dir/packet-count"
warp_matched_packets() {
    local count
    count=$(<"$test_dir/packet-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$test_dir/packet-count"
    printf '%s\n' "$count"
}
curl() { [[ "${*: -1}" == http://149.154.*/ ]] && printf '404'; }
_warp_telegram_probe
curl() { return 28; }
if _warp_telegram_probe; then exit 1; fi

# Tunnel that stalls after the first ~16 KB fails the bulk probe.
_warp_curl_route() { printf '%s\n' -x socks5h://127.0.0.1:1; }
curl() { printf '16384'; return 28; }
if _warp_bulk_probe; then exit 1; fi
curl() { printf '262144'; }
_warp_bulk_probe

# Excluded nodes (DME by default) leave the choice; best moves to the next one.
{
    printf '# Best endpoint per node\n'
    printf '%-6s %-22s %-13s %-10s %s\n' NODE ENDPOINT 'ENDPOINT PING' 'SEEN AS' 'NODE LOCATION'
    printf '%-6s %-22s %-13s %-10s %s\n' DME '188.114.98.140:2408' 1ms RU 'Moscow, RU'
    printf '%-6s %-22s %-13s %-10s %s\n' ARN '8.47.69.95:2408' 20ms RU 'Stockholm, SE'
} > "$test_dir/report"
_warp_report_to_json "$test_dir/report" | jq -e '.status=="success" and (.nodes|length)==1
    and .best_endpoint=="8.47.69.95:2408" and .excluded[0].node=="DME"' >/dev/null
{
    printf '# Best endpoint per node\n'
    printf '%-6s %-22s %-13s %-10s %s\n' NODE ENDPOINT 'ENDPOINT PING' 'SEEN AS' 'NODE LOCATION'
    printf '%-6s %-22s %-13s %-10s %s\n' DME '188.114.98.140:2408' 1ms RU 'Moscow, RU'
} > "$test_dir/report"
_warp_report_to_json "$test_dir/report" | jq -e '.status=="empty" and .best_endpoint==""' >/dev/null
# Clearing the exclusion brings DME back without a new scan.
_warp_report_to_json "$test_dir/report" > "$(_warp_scan_file)"
WARP_EXCLUDE=""
_warp_scan_reexclude
jq -e '.status=="success" and .best_endpoint=="188.114.98.140:2408" and (.excluded|length)==0' "$(_warp_scan_file)" >/dev/null
WARP_EXCLUDE="dme, led"
[ "$(_warp_excluded)" = DME,LED ]
_warp_node_excluded led
if _warp_node_excluded AMS; then exit 1; fi
_warp_scan_reexclude
jq -e '.status=="empty" and .excluded[0].node=="DME"' "$(_warp_scan_file)" >/dev/null
[ "$(_warp_parse_exclude none)" = "" ]
[ "$(_warp_parse_exclude default)" = DME ]
[ "$(_warp_parse_exclude ams,fra)" = AMS,FRA ]
if _warp_parse_exclude 'DM;E' >/dev/null; then exit 1; fi
unset WARP_EXCLUDE
[ "$(_warp_excluded)" = DME ]

# A saved state on an excluded node is not reused; a pinned address is.
WARP_MODE=upstream; WARP_PROTO=awg; WARP_LOCATION=""; WARP_ENDPOINT=""
rm -f "$(_warp_scan_file)"
jq -nc '{endpoint:"188.114.98.140:2408",proto:"awg",mode:"upstream",location:"",pin:"",node:"DME"}' > "$(_warp_state)"
if _warp_cached_endpoint >/dev/null; then exit 1; fi
WARP_EXCLUDE=""
[[ "$(_warp_cached_endpoint)" == "188.114.98.140:2408" ]]
unset WARP_EXCLUDE

# Exit through an excluded node: code 3, the wait reconnects instead of accepting.
warp_route_ready() { return 0; }
warp_exit_info() { echo "1.2.3.4|RU|DME"; }
rc=0; warp_check_route || rc=$?
[ "$rc" -eq 3 ]

# Tunnel never answers: give up after 5 tries instead of 15.
sleep() { :; }; log_info() { :; }
tries=0
warp_check_route() { tries=$((tries + 1)); return 2; }
if _warp_wait_route; then exit 1; fi
[ "$tries" -eq 5 ]
# Tunnel up but Telegram silent: keep the full wait.
tries=0
warp_check_route() { tries=$((tries + 1)); return 1; }
if _warp_wait_route; then exit 1; fi
[ "$tries" -eq 15 ]
unset -f sleep warp_check_route

# Fallback candidates: same proto and filter, scan order, no active one, no dups.
WARP_MODE=upstream
WARP_PROTO=awg
WARP_LOCATION=ARN
jq -nc '{status:"success",proto:"awg",filter:"ARN",nodes:[
    {node:"ARN",endpoint:"1.1.1.1:2408"},{node:"ARN",endpoint:"2.2.2.2:2408"},
    {node:"ARN",endpoint:"1.1.1.1:2408"},{node:"ARN",endpoint:"3.3.3.3:2408"}]}' > "$(_warp_scan_file)"
[[ "$(_warp_scan_candidates 2.2.2.2:2408 | tr '\n' ' ')" == "1.1.1.1:2408 3.3.3.3:2408 " ]]
WARP_LOCATION=AMS
[[ -z "$(_warp_scan_candidates)" ]]

echo 'warp selection: ok'
