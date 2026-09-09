#!/bin/bash
set -uo pipefail
: "${SOAK_DIR:?Set SOAK_DIR to an isolated temporary directory}"
: "${WARPSCOUT_BIN:?Set WARPSCOUT_BIN}"
: "${WARP_ACCOUNT:?Set WARP_ACCOUNT to a test account}"
: "${WARP_TEST_ENDPOINT:?Set WARP_TEST_ENDPOINT}"
repo=$(cd "$(dirname "$0")/.." && pwd)
INSTALL_DIR="$SOAK_DIR"
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/warp.sh"
WARP_ENABLED=true
WARP_MODE=upstream
WARP_PROTO=awg
WARP_LOCATION="${SOAK_LOCATION:-NL}"
WARP_SOCKS_PORT="${SOAK_PORT:-41083}"
socks_pid=
if ss -ltnH | awk '{print $4}' | grep -qE ":$WARP_SOCKS_PORT$"; then
    echo "Test port $WARP_SOCKS_PORT is busy" >&2
    exit 1
fi
mkdir -p "$(_warp_dir)" || exit 1
chmod 700 "$SOAK_DIR" "$(_warp_dir)"
printf '%s\n' "$BASHPID" > "$SOAK_DIR/pid"
sha256sum "$repo/lib/warp.sh" > "$SOAK_DIR/source.sha256"
cp "$WARPSCOUT_BIN" "$(_warp_bin)" || exit 1
cp "$WARP_ACCOUNT" "$(_warp_account)" || exit 1
chmod 700 "$(_warp_bin)"
chmod 600 "$(_warp_account)"
_warp_valid_endpoint "$WARP_TEST_ENDPOINT" || exit 1
_warp_write_state "$WARP_TEST_ENDPOINT" || exit 1
stop_socks() {
    [ -z "$socks_pid" ] || kill "$socks_pid" 2>/dev/null || true
    [ -z "$socks_pid" ] || wait "$socks_pid" 2>/dev/null || true
}
trap stop_socks EXIT
trap 'exit 143' TERM INT HUP
log_info() { printf '%s INFO %s\n' "$(date -u +%FT%TZ)" "$*"; }
log_warn() { printf '%s WARN %s\n' "$(date -u +%FT%TZ)" "$*"; }
log_error() { printf '%s ERROR %s\n' "$(date -u +%FT%TZ)" "$*"; }
log_success() { printf '%s OK %s\n' "$(date -u +%FT%TZ)" "$*"; }
_warp_unit_active() { [ -n "$socks_pid" ] && kill -0 "$socks_pid" 2>/dev/null; }
warp_route_ready() { _warp_unit_active; }
# Только запуск тестового SOCKS: службы и маршруты хоста не меняются.
_warp_start_services() {
    stop_socks
    local ep proto
    ep=$(jq -er .endpoint "$(_warp_state)") || return 1
    proto=$(jq -er .proto "$(_warp_state)") || return 1
    "$(_warp_bin)" socks -a "$(_warp_account)" -e "$ep" -p "$proto" -l 127.0.0.1 -port "$WARP_SOCKS_PORT" >> "$SOAK_DIR/socks.log" 2>&1 &
    socks_pid=$!
}
_warp_start_services || exit 1
start=$(date +%s)
injected=false
while [ "$(date +%s)" -lt "$((start + ${SOAK_SECONDS:-86400}))" ]; do
    warp_watch || true
    jq -c . "$(_warp_health_file)" >> "$SOAK_DIR/checks.jsonl"
    if [ "$injected" = false ] && [ "${INJECT_FAILURE:-true}" = true ] && jq -e '.result=="healthy"' "$(_warp_health_file)" >/dev/null; then
        log_info 'Принудительный обрыв тестового SOCKS'
        stop_socks
        injected=true
    fi
    sleep "${SOAK_INTERVAL:-60}"
done
jq -s '{completed:true,checks:length,healthy:map(select(.result=="healthy" or .result=="recovered"))|length,failed:map(select(.result=="failed"))|length,recoveries:map(select(.result=="recovered"))|length,first:.[0].checked_at,last:.[-1].checked_at}' "$SOAK_DIR/checks.jsonl" > "$SOAK_DIR/result.json"
log_info "Наблюдение завершено: $SOAK_DIR/result.json"
