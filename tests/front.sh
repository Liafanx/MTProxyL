#!/bin/bash
# Конфиги Caddy и HAProxy на всех раскладках. Проверка самими бинарниками —
# если они есть рядом; без них проверяется только сборка текста.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-front.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/config"
SETTINGS_FILE="$test_dir/settings.conf"
VERSION=test
mkdir -p "$CONFIG_DIR" "$test_dir/cert" "$test_dir/site"
exec </dev/null

# shellcheck source=/dev/null
source "$repo/lib/colors.sh" || true
for _lib in utils settings detect secrets selfmask front web; do source "$repo/lib/$_lib.sh"; done
_mktemp() { mktemp "${1:-$test_dir}/.tmp.XXXXXX"; }

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$test_dir/cert/privkey.pem" -out "$test_dir/cert/fullchain.pem" -days 2 \
    -subj /CN=site.test -addext "subjectAltName=DNS:site.test,DNS:web.site.test" 2>/dev/null

_selfmask_cert_dir() { echo "$test_dir/cert"; }
web_cert_dir() { echo "$test_dir/cert"; }
web_public_addr() { echo "203.0.113.5:443"; }
web_nginx_ipv6_available() { return 0; }
PANEL=""
_selfmask_panel_proxy_params() { [ -n "$PANEL" ] && echo "$PANEL"; }

caddy_bin=""
for _b in /opt/mtproxyl-caddy/bin/caddy "$(command -v caddy 2>/dev/null || true)"; do
    [ -x "$_b" ] && "$_b" list-modules 2>/dev/null | grep -q '^layer4$' && { caddy_bin="$_b"; break; }
done
haproxy_bin=""
for _b in /opt/mtproxyl-haproxy/sbin/haproxy "$(command -v haproxy 2>/dev/null || true)"; do
    [ -x "$_b" ] && { haproxy_bin="$_b"; break; }
done

MTPROXYL_MODE=manager
SELFMASK_DOMAIN=site.test
SELFMASK_SITE_DIR="$test_dir/site"
SELFMASK_NGINX_BACKEND_PORT=8444
WEB_DOMAIN=web.site.test
PROXY_PORT=443

check() {
    local _name="$1" _f
    _front_context
    _f="$test_dir/$_name.Caddyfile"
    _front_caddy_conf > "$_f"
    if [ -n "$caddy_bin" ]; then
        XDG_DATA_HOME="$test_dir" XDG_CONFIG_HOME="$test_dir" \
            "$caddy_bin" validate --config "$_f" --adapter caddyfile >"$test_dir/out" 2>&1 \
            || { echo "Caddy не принял конфиг «$_name»:" >&2; grep -v '"level":"info"' "$test_dir/out" >&2; cat -n "$_f" >&2; exit 1; }
    fi
    _f="$test_dir/$_name.cfg"
    _front_haproxy_conf > "$_f"
    if [ -n "$haproxy_bin" ]; then
        "$haproxy_bin" -c -q -f "$_f" >"$test_dir/out" 2>&1 \
            || { echo "HAProxy не принял конфиг «$_name»:" >&2; cat "$test_dir/out" >&2; cat -n "$_f" >&2; exit 1; }
    fi
}

has() { grep -qF -- "$2" "$test_dir/$1" || { echo "В $1 нет: $2" >&2; exit 1; }; }
hasnt() { ! grep -qF -- "$2" "$test_dir/$1" || { echo "В $1 лишнее: $2" >&2; exit 1; }; }

# Только Selfmask, Let's Encrypt: :80 и бэкенд маски, без layer4.
SELFMASK_ENABLED=true SELFMASK_CERT_MODE=letsencrypt WEB_ENABLED=false
check selfmask
has selfmask.Caddyfile "http://:80 {"
has selfmask.Caddyfile "https://site.test:8444 {"
has selfmask.Caddyfile "curves x25519mlkem768"
hasnt selfmask.Caddyfile "layer4"
has selfmask.cfg "ssl-default-bind-curves X25519MLKEM768"
has selfmask.cfg "frontend mtproxyl_http"
has selfmask.cfg "frontend mtproxyl_selfmask"
hasnt selfmask.cfg "frontend mtproxyl_public"

# Самоподписанный: :80 не занимаем, HSTS не шлём.
SELFMASK_CERT_MODE=selfsigned
check selfsigned
hasnt selfsigned.Caddyfile "http://:80"
hasnt selfsigned.Caddyfile "Strict-Transport-Security"
hasnt selfsigned.cfg "frontend mtproxyl_http"
hasnt selfsigned.cfg "set-header Strict-Transport-Security"
SELFMASK_CERT_MODE=letsencrypt

# shared: :443 разбирается по SNI, движок на приватном порту с PROXY.
WEB_ENABLED=true PROXY_MODE=combined WEB_LAYOUT=shared
check shared
has shared.Caddyfile "@web tls sni web.site.test"
has shared.Caddyfile "proxy_protocol v1"
has shared.Caddyfile "https://web.site.test:15444 {"
has shared.Caddyfile "respond 421"
has shared.Caddyfile "match header Content-Security-Policy \"default-src 'self'*\""
has shared.cfg "use_backend mtproxyl_web_tls if { req.ssl_sni -i web.site.test }"
has shared.cfg "accept-proxy ssl crt \"@mtproxyl/site\""
has shared.cfg "server mtproto 127.0.0.1:15443 send-proxy"
has shared.cfg "set-var(txn.mtproxyl_decoy)"

# split: WEB сам на публичном порту, прокси остаётся на своём.
WEB_LAYOUT=split PROXY_PORT=8443 WEB_PUBLIC_PORT=443
check split
hasnt split.Caddyfile "layer4"
has split.Caddyfile "https://web.site.test:443 {"
hasnt split.cfg "frontend mtproxyl_public"
has split.cfg "bind :443 ssl crt"
PROXY_PORT=443

# Только WEB без Selfmask: сайта маски нет, :80 и WEB остаются.
SELFMASK_ENABLED=false PROXY_MODE=web WEB_LAYOUT=shared
check webonly
hasnt webonly.Caddyfile ":8444"
has webonly.Caddyfile "https://web.site.test:443 {"
hasnt webonly.cfg "frontend mtproxyl_selfmask"
has webonly.cfg "redirect location https://web.site.test"

# Панель на домене заглушки по https.
SELFMASK_ENABLED=true PROXY_MODE=combined PANEL="/secret https 8080"
check panel
has panel.Caddyfile "redir /secret /secret/ 308"
has panel.Caddyfile "tls_insecure_skip_verify"
has panel.cfg "use_backend mtproxyl_panel if { path_beg /secret/ }"
has panel.cfg "server panel 127.0.0.1:8080 ssl verify none"

# Без держателя по умолчанию остаётся nginx.
FRONT_SERVER=""
[ "$(front_server)" = nginx ]
FRONT_SERVER=bogus
[ "$(front_server)" = nginx ]
FRONT_SERVER=caddy
[ "$(front_service)" = mtproxyl-caddy.service ]
FRONT_SERVER=haproxy
[ "$(front_units)" = "mtproxyl-haproxy.service mtproxyl-static.service" ]

echo "front: ok (caddy: ${caddy_bin:-нет}, haproxy: ${haproxy_bin:-нет})"
