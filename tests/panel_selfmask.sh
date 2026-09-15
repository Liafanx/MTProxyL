#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-panel-selfmask.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir/state"
CONFIG_DIR="$INSTALL_DIR/mtproxy"
SETTINGS_FILE="$INSTALL_DIR/settings.conf"
VERSION=dev
GITHUB_RAW="https://example.invalid"
BOLD="" DIM="" NC="" GREEN="" YELLOW="" RED="" BLUE="" CYAN=""
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/config.sh"
source "$repo/lib/web.sh"
source "$repo/lib/selfmask.sh"
source "$repo/lib/panel.sh"

PANEL_CONFIG_DIR="$test_dir/panel"
PANEL_BINARY="$test_dir/mtproxyl-panel"
PANEL_SERVICE="mtproxyl-panel-test"
mkdir -p "$PANEL_CONFIG_DIR"
printf '#!/bin/sh\nexit 0\n' > "$PANEL_BINARY"
chmod 700 "$PANEL_BINARY"

log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { :; }
check_root() { :; }
systemctl() { :; }
_mktemp() { mktemp "${1:-$test_dir}/fixture.XXXXXX"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

PANEL_SELFMASK_ENABLED=true
PANEL_SELFMASK_PATH="/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PANEL_SELFMASK_PREV_LISTEN="0.0.0.0:8080"
PANEL_SELFMASK_PREV_BASE_PATH="/old-panel"
IPBLOCK_ENABLED=false
IPBLOCK_ACTION=drop
IPBLOCK_LIST=""
IPBLOCK_LIST6=""
save_settings
[[ $(stat -c '%a' "$PANEL_SELFMASK_STATE_FILE") == 600 ]] || fail 'panel token state is not root-only'
! grep -q '^PANEL_SELFMASK_' "$SETTINGS_FILE" || fail 'panel token leaked into world-readable settings.conf'
PANEL_SELFMASK_ENABLED=false
PANEL_SELFMASK_PATH=""
PANEL_SELFMASK_PREV_LISTEN=""
PANEL_SELFMASK_PREV_BASE_PATH=""
load_panel_selfmask_settings
[[ "$PANEL_SELFMASK_ENABLED" == true ]] || fail 'panel state enabled flag not loaded'
[[ "$PANEL_SELFMASK_PATH" == "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] || fail 'panel token state not loaded'
save_settings() { :; }

SELFMASK_ENABLED=true
SELFMASK_DOMAIN=mask.example.com
PROXY_PORT=443
NGINX_CUSTOM_ENABLED=false
PANEL_SELFMASK_ENABLED=false
PANEL_SELFMASK_PATH=""
PANEL_SELFMASK_PREV_LISTEN=""
PANEL_SELFMASK_PREV_BASE_PATH=""

generated_path=$(_panel_selfmask_random_path)
[[ "$generated_path" =~ ^/[0-9a-f]{32}$ ]] || fail 'random path must be a bare 32-character token'

cat > "$PANEL_CONFIG_DIR/config.toml" <<'EOF'
# Одинарные кавычки — валидный TOML. Панель такой конфиг читает,
# и panel selfmask on не должен терять из него порт.
listen = '0.0.0.0:8080' # коммент после значения тоже допустим
base_path = '/old-panel'

[telemt]
url = "http://127.0.0.1:9091"

[tls]
cert_file = "/tmp/panel.crt"
key_file = "/tmp/panel.key"
EOF

captured_nginx=""
_selfmask_configure_nginx() {
    captured_nginx=$(_selfmask_panel_proxy_block)
}

panel_selfmask_enable /0123456789abcdef0123456789abcdef
[[ $(_panel_config_value listen) == "127.0.0.1:8080" ]] || fail 'backend is not loopback-only'
[[ $(_panel_config_value base_path) == "/0123456789abcdef0123456789abcdef" ]] || fail 'base_path not applied'
[[ "$PANEL_SELFMASK_PREV_LISTEN" == "0.0.0.0:8080" ]] || fail 'previous listen not saved'
[[ "$PANEL_SELFMASK_PREV_BASE_PATH" == "/old-panel" ]] || fail 'previous base_path not saved'
[[ "$captured_nginx" == *'location ^~ /0123456789abcdef0123456789abcdef/'* ]] || fail 'nginx location missing'
[[ "$captured_nginx" == *'proxy_pass https://127.0.0.1:8080;'* ]] || fail 'TLS upstream not detected'
[[ "$captured_nginx" == *'X-Forwarded-Proto https'* ]] || fail 'forwarded HTTPS marker missing'
[[ "$captured_nginx" == *'X-Forwarded-For $remote_addr'* ]] || fail 'client IP is not overwritten by trusted nginx'
[[ "$captured_nginx" != *'$proxy_add_x_forwarded_for'* ]] || fail 'spoofable forwarded chain is preserved'
[[ "$captured_nginx" == *'client_max_body_size 8m;'* ]] || fail 'panel uploads limited by nginx'
[[ $(panel_public_url) == "https://mask.example.com/0123456789abcdef0123456789abcdef/" ]] || fail 'public URL incorrect'
tls_proxy_block="$captured_nginx"

captured_nginx=""
panel_selfmask_enable
[[ "$captured_nginx" == *'location ^~ /0123456789abcdef0123456789abcdef/'* ]] || fail 'idempotent apply did not refresh nginx'
[[ $(_panel_config_value listen) == "127.0.0.1:8080" ]] || fail 'idempotent apply changed listen'

panel_selfmask_disable
[[ $(_panel_config_value listen) == "0.0.0.0:8080" ]] || fail 'listen not restored'
[[ $(_panel_config_value base_path) == "/old-panel" ]] || fail 'base_path not restored'
[[ "$PANEL_SELFMASK_ENABLED" == "false" ]] || fail 'mode not disabled'
[[ -z "$captured_nginx" ]] || fail 'nginx location not removed'

# WEB alone also publishes the same authenticated panel path.
SELFMASK_ENABLED=false
WEB_ENABLED=true
PROXY_MODE=web
WEB_FRONTEND=nginx
WEB_DOMAIN=web.example.com
panel_selfmask_enable /0123456789abcdef0123456789abcdef
[[ $(panel_public_url) == 'https://web.example.com/0123456789abcdef0123456789abcdef/' ]] || fail 'WEB panel URL incorrect'
web_block=$(web_nginx_http_server /tmp/certs)
[[ "$web_block" == *'location ^~ /0123456789abcdef0123456789abcdef/'* ]] || fail 'WEB panel route missing'
[[ "$SELFMASK_ENABLED" == false ]] || fail 'WEB panel enabled Selfmask'
panel_selfmask_disable
WEB_ENABLED=false
PROXY_MODE=mtproto
SELFMASK_ENABLED=true
# HTTP backend is valid too: external HTTPS still terminates at Selfmask.
sed -i '/^\[tls\]/,$d' "$PANEL_CONFIG_DIR/config.toml"
_panel_config_set_access "127.0.0.1:8080" "/fedcba9876543210fedcba9876543210"
PANEL_SELFMASK_ENABLED=true
PANEL_SELFMASK_PATH="/fedcba9876543210fedcba9876543210"
http_block=$(_selfmask_panel_proxy_block)
[[ "$http_block" == *'proxy_pass http://127.0.0.1:8080;'* ]] || fail 'HTTP upstream not detected'
[[ "$http_block" != *'proxy_ssl_verify'* ]] || fail 'TLS options emitted for HTTP upstream'

# base_path alone must never publish a panel without explicit opt-in.
PANEL_SELFMASK_ENABLED=false
[[ -z $(_selfmask_panel_proxy_block) ]] || fail 'implicit panel exposure'

# Если nginx из состава MTProxyL доступен, проверяем не только текст блока,
# но и настоящий синтаксический разбор его конфигурации.
nginx_bin="${NGINX_TEST_BIN:-/opt/mtproxyl-nginx/sbin/nginx}"
if [ -x "$nginx_bin" ] && command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=mask.example.com' \
        -keyout "$test_dir/key.pem" -out "$test_dir/cert.pem" >/dev/null 2>&1
    {
        printf 'pid %s;\n' "$test_dir/nginx.pid"
        printf 'error_log %s;\n' "$test_dir/nginx-error.log"
        printf 'events { worker_connections 16; }\n'
        printf 'http { server { listen 127.0.0.1:18444 ssl;\n'
        printf 'ssl_certificate %s; ssl_certificate_key %s;\n' "$test_dir/cert.pem" "$test_dir/key.pem"
        printf '%s\n' "$tls_proxy_block"
        printf 'location / { return 404; }\n} }\n'
    } > "$test_dir/nginx.conf"
    "$nginx_bin" -t -p "$test_dir/" -c "$test_dir/nginx.conf" >/dev/null 2>&1 || \
        fail 'nginx rejected generated proxy block'
fi

echo 'panel selfmask tests: OK'
