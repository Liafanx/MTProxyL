#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
INSTALL_DIR=/nonexistent
source "$repo/lib/web.sh"
source "$repo/lib/selfmask.sh"

WEB_ENABLED=true
WEB_FRONTEND=nginx
WEB_LAYOUT=shared
WEB_DOMAIN=web.example.com
WEB_TLS_PORT=15444
WEB_LISTEN_PORT=15080
WEB_DECOY_MODE=empty
SELFMASK_DOMAIN=mask.example.com
SELFMASK_SITE_DIR=/var/www/my-mask-site
SELFMASK_NGINX_BACKEND_PORT=8444

server=$(web_nginx_http_server /tmp/test-cert)
[[ "$server" == *'listen 127.0.0.1:15444 ssl proxy_protocol;'* ]]
[[ "$server" == *'proxy_pass http://127.0.0.1:15080;'* ]]

log_warn() { printf '%s\n' "$*"; }
log_info() { printf '%s\n' "$*"; }
notice=$(_selfmask_web_decoy_notice)
[[ "$notice" == *'пустую заглушку'* ]]
[[ "$notice" == *'WEB_DECOY_MODE static_directory'* ]]
[[ "$notice" == *'/var/www/my-mask-site'* ]]

WEB_DECOY_MODE=static_directory
[[ -z "$(_selfmask_web_decoy_notice)" ]]
decoy=$(_web_decoy_toml)
[[ "$decoy" == *'mode = "static_directory"'* ]]
[[ "$decoy" == *'directory = "/var/www/my-mask-site"'* ]]

echo 'Selfmask and WEB decoy routing: OK'
