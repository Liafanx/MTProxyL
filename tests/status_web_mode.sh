#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-status-mode.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test

source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/web.sh"
source "$repo/lib/traffic.sh"

is_proxy_running() { return 1; }
MTPROXYL_MODE=manager
PROXY_PORT=443
PROXY_DOMAIN=proxy.example.com
WEB_ENABLED=true
WEB_DOMAIN=web.example.com
WEB_LAYOUT=shared
WEB_CARRIER=websocket

PROXY_MODE=web
show_status_json | jq -e '.web.enabled == true and .web.proxy_mode == "web"' >/dev/null
PROXY_MODE=combined
show_status_json | jq -e '.web.proxy_mode == "combined"' >/dev/null

echo 'status WEB mode: OK'
