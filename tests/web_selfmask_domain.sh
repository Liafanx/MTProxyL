#!/bin/bash
set -euo pipefail
INSTALL_DIR=/nonexistent
source "$(dirname "$0")/../lib/web.sh"
log_error() { :; }
log_info() { :; }
WEB_DOMAIN=web.example.com
SELFMASK_ENABLED=false
SELFMASK_DOMAIN=""
SELFMASK_SITE_DIR=/tmp/mtproxyl-unused-site
WEB_DECOY_MODE=upstream
engine_is_binary() { return 1; }
build_telemt_image() { return 0; }
web_uses_managed_nginx() { return 1; }
_web_prepare_frontend
[[ -z "$SELFMASK_DOMAIN" ]]
_selfmask_obtain_cert() { [[ "$SELFMASK_DOMAIN" == "$expected" ]]; }
expected=web.example.com
_web_obtain_cert
[[ -z "$SELFMASK_DOMAIN" ]]
[[ "$SELFMASK_ENABLED" == false ]]
SELFMASK_ENABLED=true
SELFMASK_DOMAIN=mask.example.com
expected=mask.example.com
_web_obtain_cert
[[ "$SELFMASK_DOMAIN" == mask.example.com ]]

# WEB нельзя снять, оставив скрытую панель только на loopback.
SELFMASK_ENABLED=false
WEB_ENABLED=true
PROXY_MODE=combined
WEB_LAYOUT=split
PANEL_SELFMASK_ENABLED=true
panel_disable_called=false
panel_selfmask_disable() { panel_disable_called=true; return 1; }
if web_disable; then
    exit 1
fi
[[ "$panel_disable_called" == true ]]
[[ "$WEB_ENABLED" == true ]]

# В неинтерактивной первой установке отдельный MTProto-порт означает split,
# если пользователь явно не потребовал другую раскладку.
source "$(dirname "$0")/../lib/install_args.sh"
draw_header() { :; }
save_settings() { :; }
chosen_layout=""
web_enable() { chosen_layout="$WEB_LAYOUT"; }
PROXY_MODE=combined
PROXY_PORT=2053
SELFMASK_ENABLED=false
_IA_WEB_LAYOUT=""
_install_args_web
[[ "$chosen_layout" == split ]]
echo 'WEB certificate domain isolation: OK'
