#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-web-csp.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
WEB_FP_SEED=0123456789abcdef
mkdir -p "$CONFIG_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/web.sh"

csp=$(web_csp_policy)

[[ "$csp" == *"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com"* ]]
[[ "$csp" == *"script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://unpkg.com"* ]]
[[ "$csp" == *"font-src 'self' data: https://fonts.gstatic.com"* ]]

echo 'WEB CSP: OK'
