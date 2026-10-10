#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-install-carriers.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/state"
CONFIG_DIR="$INSTALL_DIR/mtproxy"
SETTINGS_FILE="$INSTALL_DIR/settings.conf"
VERSION=dev
GITHUB_RAW="https://example.invalid"
BOLD="" DIM="" NC="" GREEN="" YELLOW="" RED="" BLUE="" CYAN=""
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

for _lib in utils settings selfmask web install_args; do source "$repo/lib/$_lib.sh"; done
log_info() { :; }; log_success() { :; }; log_warn() { :; }; log_error() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }

_install_args_parse --mode manager --web yes --web-domain web.example.com --web-carriers WebSocket-Lanes,https
[ "$_IA_WEB_CARRIERS" = "websocket-lanes,https" ] || fail 'carriers not parsed'
_install_args_validate || fail 'valid carriers rejected'

_IA_WEB_CARRIERS="https;id"
if _install_args_validate; then fail 'bad carriers accepted'; fi
_IA_WEB_CARRIERS="quic"
if _install_args_validate; then fail 'unknown carrier accepted'; fi

_IA_WEB_CARRIERS="https"; _IA_WEB=""
if _install_args_validate; then fail 'carriers without --web yes accepted'; fi

echo "install args web carriers: ok"
