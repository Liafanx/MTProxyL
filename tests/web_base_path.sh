#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-web-base-path.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
mkdir -p "$CONFIG_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/selfmask.sh"
source "$repo/lib/web.sh"

secret=000102030405060708090a0b0c0d0e0f
engine_current_version() { echo "$ENGINE"; }
# `! cmd` под set -e ничего не проверяет — отказ проверяем явно.
fails() { if "$@" >/dev/null 2>&1; then echo "Должно было не пройти: $*" >&2; exit 1; fi; }

# Формат ссылок сверяется с документацией telemt 3.5.8.
[ "$(web_format_link proxy.example.com telegram/web plain "$secret")" = \
  'tg://webproxy?server=proxy.example.com%2Ftelegram%2Fweb&secret=cAABAgMEBQYHCAkKCwwNDg8' ]
[ "$(web_format_link proxy.example.com telegram/web dd "$secret")" = \
  'tg://webproxy?server=proxy.example.com%2Ftelegram%2Fweb&secret=cN0AAQIDBAUGBwgJCgsMDQ4P' ]
[ "$(web_format_link proxy.example.com '' dd "$secret")" = \
  "tg://webproxy?server=proxy.example.com&secret=dd${secret}" ]
fails web_format_link proxy.example.com '' dd nothex

for ok in app app/sync A1/b_2/c-3; do _validate_web_base_path "$ok"; done
for bad in /app app/ app//x 'a b' -app app/.x "$(printf 'a%.0s' {1..129})"; do
    fails _validate_web_base_path "$bad"
done
PANEL_SELFMASK_PATH=/panel
fails _validate_web_base_path panel/x
_validate_web_base_path panelx
PANEL_SELFMASK_PATH=""

# Путь и sideband пишутся только для движка, который их знает.
WEB_BASE_PATH=app/sync WEB_DEBUG=true WEB_DEBUG_SIDEBAND=true
ENGINE=3.5.8
[ "$(web_base_path)" = app/sync ]
web_sideband_enabled
ENGINE=3.5.7
[ -z "$(web_base_path)" ]
fails web_engine_supports_path
WEB_DEBUG=false
fails web_sideband_enabled

echo 'WEB base_path: OK'
