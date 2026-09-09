#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-unit.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
VERSION=1.6.12
BOLD="" DIM="" NC="" GREEN="" YELLOW="" RED="" BLUE=""
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/config.sh"
source "$repo/lib/expert_mode.sh"
source "$repo/lib/web.sh"
source "$repo/lib/warp.sh"
source "$repo/lib/settings_cli.sh"
mkdir -p "$(_warp_dir)"
log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { :; }
check_root() { :; }
_mktemp() { mktemp "${1:-$test_dir}/fixture.XXXXXX"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $(proxy_log_level) == silent ]] || fail 'default log level'
printf 'log_level|verbose\n' > "$_TUNE_FILE"
[[ $(proxy_log_level) == verbose ]] || fail 'preserve tune'
save_expert_override general log_level normal
[[ $(proxy_log_level) == normal ]] || fail 'preserve explicit normal'
save_expert_override general log_level debug
[[ $(proxy_log_level) == debug ]] || fail 'expert precedence'

headers=$(https_nginx_headers letsencrypt)
[[ "$headers" == *'max-age=15552000'* && "$headers" != *includeSubDomains* && "$headers" != *preload* ]] || fail 'HSTS scope'
[[ "$headers" == *'camera=(), microphone=(), geolocation=()'* ]] || fail 'permissions policy'
HTTPS_HSTS_ENABLED=false
[[ $(https_nginx_headers letsencrypt) == *'max-age=0'* ]] || fail 'HSTS removal'
HTTPS_PERMISSIONS_ENABLED=false
[[ -z $(https_nginx_headers selfsigned) ]] || fail 'selfsigned HSTS'
HTTPS_HSTS_ENABLED=true
HTTPS_PERMISSIONS_ENABLED=true

for endpoint in 188.114.98.58:2408 '[2606:4700:d0::a29f:c001]:2408' '[::1]:443' '[::1:2:3:4:5:6:7]:443' '[1:2:3:4:5:6:7::]:443' '[::ffff:192.0.2.1]:443'; do
    _warp_valid_endpoint "$endpoint" || fail "valid endpoint $endpoint"
done
for endpoint in 999.1.1.1:443 127.0.0.1:0 127.0.0.1:65536 '[:::1]:443' '[::1%eth0]:443' '[:1::2]:443' '[1.2.3.4]:443' 'localhost:443' '1.2.3.4:80;id'; do
    if _warp_valid_endpoint "$endpoint"; then fail "invalid endpoint $endpoint"; fi
done

report="$test_dir/report"
report_fixture() {
    printf '# Best endpoint per node (lowest loss, then RTT)\n'
    printf '%-6s %-22s %-13s %-9s %-6s %-11s %-10s %s\n' NODE ENDPOINT 'ENDPOINT PING' 'TUN PING' LOSS SPEED 'SEEN AS' 'NODE LOCATION'
    printf '%-6s %-22s %-13s %-9s %-6s %-11s %-10s %s\n' FRA '188.114.98.58:2408' '?' 25ms 0% 32Mbps DE 'Frankfurt, Germany'
    printf '%-6s %-22s %-13s %-9s %-6s %-11s %-10s %s\n' AMS '[2606:4700:d0::a29f:c001]:2408' 20ms 30ms 1% 30Mbps NL 'Amsterdam, Netherlands'
}
report_fixture > "$report"
_warp_report_to_json "$report" > "$test_dir/result"
jq -e '.status=="success" and .nodes[0].region=="DE" and .nodes[0].loss=="0%" and .nodes[1].region=="NL" and .nodes[1].tunnel_ping=="30ms" and .best_endpoint=="188.114.98.58:2408"' "$test_dir/result" >/dev/null || fail 'report with optional columns/IPv6'
{
    printf '# Best endpoint per node\n'
    printf '%-6s %-22s %-13s %-10s %s\n' NODE ENDPOINT 'ENDPOINT PING' 'SEEN AS' 'NODE LOCATION'
    printf '%-6s %-22s %-13s %-10s %s\n' FRA '188.114.98.58:2408' 25ms DE 'Frankfurt'
} > "$report"
_warp_report_to_json "$report" | jq -e '.nodes[0].region=="DE" and .nodes[0].tunnel_ping==""' >/dev/null || fail 'old report'
printf 'No working endpoints found.\n' > "$report"
_warp_report_to_json "$report" | jq -e '.status=="empty" and (.nodes|length)==0' >/dev/null || fail 'empty report'

{
    printf '# WARP endpoints: 3 working / 4 probed\n'
    printf '%-22s %-13s %-9s %-6s %-10s %-6s %s\n' ENDPOINT 'ENDPOINT PING' 'TUN PING' LOSS 'SEEN AS' NODE 'NODE LOCATION'
    printf '%-22s %-13s %-9s %-6s %-10s %-6s %s\n' '188.114.98.58:2408' 4ms 5ms 0% NL AMS Amsterdam
    printf '%-22s %-13s %-9s %-6s %-10s %-6s %s\n' '188.114.98.58:4500' 4ms 6ms 0% NL AMS Amsterdam
    printf '%-22s %-13s %-9s %-6s %-10s %-6s %s\n' '[2606:4700:d0::a29f:c001]:2408' 5ms 7ms 1% NL AMS Amsterdam
    printf '\n# 1 torn down (handshake ok, then cut)\n'
    printf '%-22s %-13s %-9s %-6s %-10s %-6s %s\n' ENDPOINT 'ENDPOINT PING' 'TUN PING' LOSS 'SEEN AS' NODE 'NODE LOCATION'
    printf '%-22s %-13s %-9s %-6s %-10s %-6s %s\n' '188.114.98.99:2408' 1ms 1ms 100% NL AMS Amsterdam
    printf '\n'
    report_fixture
} > "$report"
_warp_report_to_json "$report" | jq -e '(.nodes|length)==3 and .nodes[1].endpoint=="188.114.98.58:4500" and .nodes[2].node=="AMS" and .best_endpoint=="188.114.98.58:2408"' >/dev/null || fail 'full report must retain multiple endpoints of one node and exclude torn tunnels'

report_fixture > "$report"
export TEST_REPORT="$report" TEST_CALLS="$test_dir/calls"
cat > "$(_warp_bin)" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
if [ "${TEST_SCAN_FAIL:-0}" = 1 ]; then echo 'fixture scan failure' >&2; exit 7; fi
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then cp "$TEST_REPORT" "$2"; exit 0; fi
    shift
done
echo '188.114.98.58:2408'
MOCK
chmod 700 "$(_warp_bin)"
warp_scan_collect
[[ $(wc -l < "$TEST_CALLS") == 1 ]] || fail 'scan runs once'
jq -e '.status=="success"' "$(_warp_scan_file)" >/dev/null

WARP_MODE=socks WARP_PROTO=awg WARP_LOCATION=FRA WARP_ENDPOINT=""
: > "$TEST_CALLS"
[[ $(warp_resolve_endpoint) == 188.114.98.58:2408 ]] || fail 'cached node selection'
[[ ! -s "$TEST_CALLS" ]] || fail 'selected node scanned again'
WARP_LOCATION="" WARP_ENDPOINT='[2606:4700:d0::a29f:c001]:2408'
[[ $(warp_resolve_endpoint) == '[2606:4700:d0::a29f:c001]:2408' ]] || fail 'cached exact selection'
[[ ! -s "$TEST_CALLS" ]] || fail 'selected endpoint scanned again'
WARP_LOCATION=AMS WARP_ENDPOINT="" WARP_PROTO=masque
masque_args=$(_warp_scan_args)
[[ "$masque_args" == *$'-p\nmasque'* ]] || fail 'masque protocol missing'
[[ "$masque_args" != *'-node'* && "$masque_args" != *'-country'* ]] || fail 'masque received location filters'
WARP_PROTO=awg WARP_LOCATION=FRA

wg_key="$(printf 'A%.0s' {1..43})="
jq -nc --arg key "$wg_key" '{private_key:$key,peer_public_key:$key,ipv4:"172.16.0.2"}' > "$(_warp_account)"
WARP_MODE=iface
: > "$TEST_CALLS"
_warp_generate_iface_conf 188.114.98.58:2408
grep -q '^Address = 172.16.0.2/32$' "$(_warp_conf)" || fail 'generated WireGuard address'
grep -q '^Endpoint = 188.114.98.58:2408$' "$(_warp_conf)" || fail 'generated WireGuard endpoint'
grep -q '^Table = off$' "$(_warp_conf)" || fail 'generated WireGuard table policy'
[[ $(stat -c '%a' "$(_warp_conf)") = 600 ]] || fail 'WireGuard config permissions'
[[ ! -s "$TEST_CALLS" ]] || fail 'variant B rescanned selected endpoint'
WARP_MODE=socks

export TEST_SCAN_FAIL=1
if warp_scan_collect 2>/dev/null; then fail 'scan error ignored'; fi
jq -e '.status=="error" and (.nodes|length)==0' "$(_warp_scan_file)" >/dev/null
unset TEST_SCAN_FAIL
warp_scan_best 188.114.98.58 2408 >/dev/null
tail -1 "$TEST_CALLS" | grep -q -- '-target 188.114.98.58 -port 2408' || fail 'exact port'

WARP_ENABLED=true
WARP_WATCHDOG_ENABLED=true
warp_check_route() { return 1; }
warp_recover() {
    echo recovered >> "$test_dir/recoveries"
    _warp_health_save 0 "$(date +%s)" recovered
}
warp_watch
warp_watch
[[ ! -f "$test_dir/recoveries" ]] || fail 'recovery too early'
warp_watch
[[ $(wc -l < "$test_dir/recoveries") == 1 ]] || fail 'third failure recovery'
warp_watch; warp_watch; warp_watch
[[ $(wc -l < "$test_dir/recoveries") == 1 ]] || fail 'recovery cooldown'
warp_check_route() { return 0; }
warp_watch
jq -e '.failures==0 and .result=="healthy"' "$(_warp_health_file)" >/dev/null
WARP_WATCHDOG_ENABLED=false
warp_check_route() { fail 'disabled watchdog checked network'; }
warp_watch

(
    WARP_MODE=socks WARP_SOCKS_PORT=41080 WARP_REDIR_PORT=41081
    _warp_tcp_port_busy() { [ "$1" = 41080 ] || [ "$1" = 41081 ]; }
    _warp_select_runtime_ports
    [[ "$WARP_SOCKS_PORT:$WARP_REDIR_PORT" = 41082:41083 ]] || fail 'occupied WARP ports not replaced'
)

(
    tries=0
    sleep() { :; }
    warp_check_route() { tries=$((tries + 1)); [ "$tries" -ge 5 ]; }
    _warp_wait_route
    [[ "$tries" -eq 5 ]] || fail 'route confirmation did not retry'
)

(
    MTPROXYL_MODE=manager
    SUPEREXPERT_ENABLED=false
    MTPROXYL_ASSUME_YES=1
    _warp_me_enabled() { return 0; }
    _warp_owns_engine_config() { return 0; }
    load_upstreams() {
        UPSTREAM_NAMES=(direct scoped)
        UPSTREAM_ENABLED=(true true)
        UPSTREAM_SCOPES=("" local)
    }
    warp_preflight upstream | jq -e '.middle_proxy_enabled and .can_disable_middle_proxy and .default_upstreams==["direct"] and .can_disable_default_upstreams' >/dev/null || fail 'preflight conflicts'
    handle_expert_command() { printf '%s\n' "$*" > "$test_dir/me-consent"; }
    WARP_ALLOW_DISABLE_ME=false
    if _warp_me_gate >/dev/null 2>&1; then fail 'ME disabled without consent'; fi
    [ ! -f "$test_dir/me-consent" ] || fail 'ME mutation without consent'
    WARP_ALLOW_DISABLE_ME=true
    _WARP_CONFIG_DIRTY=false
    _warp_me_gate >/dev/null
    grep -q 'set general use_middle_proxy false' "$test_dir/me-consent" || fail 'ME consent not applied'
    [ "$_WARP_CONFIG_DIRTY" = true ] || fail 'ME config not marked dirty'
    upstream_toggle() { printf 'toggle %s %s\n' "$1" "$2" >> "$test_dir/routes-consent"; }
    upstream_remove() { :; }
    upstream_add() { :; }
    _warp_local_mask_backend() { return 1; }
    WARP_ALLOW_DISABLE_DEFAULT_UPSTREAMS=false
    if _warp_apply_upstream >/dev/null 2>&1; then fail 'default route disabled without consent'; fi
    [ ! -f "$test_dir/routes-consent" ] || fail 'route mutation without consent'
    WARP_ALLOW_DISABLE_DEFAULT_UPSTREAMS=true
    _warp_apply_upstream >/dev/null
    grep -q 'toggle direct disable' "$test_dir/routes-consent" || fail 'route consent not applied'
    ! grep -q 'toggle scoped disable' "$test_dir/routes-consent" || fail 'scoped route disabled'
)

save_settings() { printf '%s|%s|%s\n' "$WARP_PROTO" "$WARP_LOCATION" "$WARP_ENDPOINT" > "$test_dir/saved"; }
warp_set_settings awg DE 188.114.98.58:2408
before=$(cat "$test_dir/saved")
if warp_set_settings wg DE invalid; then fail 'invalid compound settings accepted'; fi
[[ $(cat "$test_dir/saved") == "$before" ]] || fail 'partial settings write'

load_settings() { :; }
_warp_dispatch() { echo "$1"; }
exec {lock}>"$INSTALL_DIR/.warp.lock"
flock -n "$lock"
if handle_warp_command apply >/dev/null; then fail 'concurrent operation allowed'; fi
[[ -z $(handle_warp_command watch) ]] || fail 'busy watchdog dispatched during manual operation'
[[ $(handle_warp_command status) == status ]] || fail 'status blocked during scan'
flock -u "$lock"

(
    load_secrets() { :; }
    load_upstreams() { :; }
    generate_telemt_config() { :; }
    is_proxy_running() { return 1; }
    _warp_stop_runtime() { echo stop >> "$test_dir/rollback"; }
    _warp_start_services() { echo start >> "$test_dir/rollback"; }
    warp_install_watchdog() { :; }
    _warp_enable() {
        _WARP_RUNTIME_CHANGED=true
        printf changed > "$INSTALL_DIR/settings.conf"
        return 1
    }
    printf original > "$INSTALL_DIR/settings.conf"
    if warp_enable iface; then fail 'failed enable succeeded'; fi
    [[ $(cat "$INSTALL_DIR/settings.conf") == original ]] || fail 'enable rollback lost settings'
    grep -q start "$test_dir/rollback" || fail 'previous runtime not restored'
    _warp_enable() {
        printf changed > "$INSTALL_DIR/settings.conf"
        return 1
    }
    rm "$test_dir/rollback"
    if warp_enable iface; then fail 'failed preflight succeeded'; fi
    [[ $(cat "$INSTALL_DIR/settings.conf") == original ]] || fail 'preflight rollback lost settings'
    [[ ! -f "$test_dir/rollback" ]] || fail 'preflight failure restarted runtime'
    MTPROXYL_MODE=reanimator
    generate_telemt_config() { touch "$test_dir/foreign-config-touched"; }
    _warp_enable() { _WARP_RUNTIME_CHANGED=true; return 1; }
    if warp_enable iface; then fail 'failed reanimator enable succeeded'; fi
    [[ ! -e "$test_dir/foreign-config-touched" ]] || fail 'rollback changed foreign engine config'
)

(
    mkdir "$test_dir/artifact-units"
    _warp_dir() { echo "$test_dir/no-warp-directory"; }
    _warp_unit_dir() { echo "$test_dir/artifact-units"; }
    if _warp_has_artifacts; then fail 'empty WARP artifacts detected'; fi
    : > "$test_dir/artifact-units/$WARP_WATCH_UNIT.service"
    _warp_has_artifacts || fail 'orphan watchdog unit not detected for uninstall'
)

(
    mkdir "$test_dir/units"
    _warp_unit_dir() { echo "$test_dir/units"; }
    systemctl() { printf '%s\n' "$*" >> "$test_dir/systemctl"; }
    ip() { :; }
    nft() { :; }
    _warp_me_enabled() { return 0; }
    _warp_owns_engine_config() { return 1; }
    _warp_generate_nft() { printf '#!/bin/sh\nexit 0\n' > "$(_warp_nft_script)"; }
    WARP_WATCHDOG_ENABLED=true
    WARP_ENABLED=false
    : > "$test_dir/systemctl"
    warp_refresh
    grep -q "disable --now $WARP_WATCH_UNIT.timer" "$test_dir/systemctl" || fail 'disabled install left watchdog enabled'
    [[ -z $(find "$test_dir/units" -type f -print) ]] || fail 'disabled install created watchdog units'
    WARP_ENABLED=true
    for WARP_MODE in socks iface upstream; do
        : > "$test_dir/systemctl"
        _warp_start_services
        case "$WARP_MODE" in
            socks) grep -q "restart $WARP_REDSOCKS_UNIT" "$test_dir/systemctl" ;;
            iface) grep -q "restart $WARP_ROUTE_UNIT" "$test_dir/systemctl" ;;
            upstream) ! grep -q "restart $WARP_REDSOCKS_UNIT" "$test_dir/systemctl" ;;
        esac
        warp_install_watchdog
        grep -q 'OnUnitInactiveSec=60s' "$test_dir/units/$WARP_WATCH_UNIT.timer"
        grep -q 'KillMode=control-group' "$test_dir/units/$WARP_WATCH_UNIT.service"
    done
    warp_remove
    grep -q "stop $WARP_WATCH_UNIT.service" "$test_dir/systemctl" || fail 'watchdog service not stopped on remove'
    [[ ! -d "$(_warp_dir)" ]] || fail 'WARP files left after remove'
    [[ -z $(find "$test_dir/units" -type f -print) ]] || fail 'WARP units left after remove'
)

(
    mkdir -p "$(_warp_dir)"
    WARP_MODE=iface
    WARP_PROTO=awg
    _warp_write_state 188.114.98.58:2408
    warp_exit_info() { return 1; }
    _warp_unit_active() { return 1; }
    ip() { return 1; }
    _warp_nft_applied() { return 1; }
    warp_matched_packets() { echo 0; }
    _warp_bin_version() { echo 0.16.0; }
    printf '91.108.4.0/22\n' > "$(_warp_cidr)"
    warp_status_json | jq -e '.active_endpoint=="188.114.98.58:2408" and .active_proto=="wg" and .proto=="awg" and .version=="0.16.0" and (.health|type)=="object"' >/dev/null || fail 'invalid status JSON'
)

if command -v visudo >/dev/null; then
    awk '/^\$SYSTEM_USER ALL=.* warp / {sub(/\$SYSTEM_USER/, "nobody");sub(/\$_script/, "/opt/mtproxyl/mtproxyl.sh");print}' "$repo/mtproxyl-panel/install.sh" > "$test_dir/sudoers"
    visudo -cf "$test_dir/sudoers" >/dev/null || fail 'invalid WARP sudoers'
fi

echo 'PASS: logging, headers, endpoints, reports, scan errors, watchdog, settings, locking, A/B/C service recovery, removal, status JSON, sudoers'
