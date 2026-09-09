#!/bin/bash
set -euo pipefail
: "${TELEMT_BIN:?Set TELEMT_BIN to telemt 3.5.7}"
NGINX_BIN=${NGINX_BIN:-/opt/mtproxyl-nginx/sbin/nginx}
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-https.XXXXXX)
telemt_pid= nginx_pid=
cleanup() {
    [ -z "$nginx_pid" ] || kill "$nginx_pid" 2>/dev/null || true
    [ -z "$telemt_pid" ] || kill "$telemt_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    if [ "${KEEP_TEST_FILES:-false}" != true ]; then rm -rf "$test_dir"; else echo "Test files: $test_dir"; fi
}
trap cleanup EXIT
for port in 25080 25443 29091 29090; do
    if ss -ltnH | awk '{print $4}' | grep -qE ":$port$"; then echo "Test port $port is busy" >&2; exit 1; fi
done
chmod 755 "$test_dir"
mkdir "$test_dir/site"
printf '<!doctype html><title>Example</title><link rel="stylesheet" href="/style.css"><script src="/app.js"></script>' > "$test_dir/site/index.html"
printf 'body { color: blue; }' > "$test_dir/site/style.css"
printf 'window.example = true;' > "$test_dir/site/app.js"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$test_dir/privkey.pem" -out "$test_dir/fullchain.pem" -days 1 -subj /CN=example.test >/dev/null 2>&1
cat > "$test_dir/telemt.toml" <<EOF
[general]
use_middle_proxy = false
log_level = "silent"
prefer_ipv6 = false
[general.modes]
classic = false
secure = true
tls = false
[server]
metrics_listen = "127.0.0.1:29090"
[[server.listeners]]
ip = "127.0.0.1"
port = 25080
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]
[server.api]
enabled = true
listen = "127.0.0.1:29091"
whitelist = ["127.0.0.1/32"]
[access.users]
example = "0123456789abcdef0123456789abcdef"
[web]
enabled = true
carrier = "websocket"
[[web.vhosts]]
host = "example.test"
public_addr = "203.0.113.10:443"
[web.vhosts.decoy]
mode = "static_directory"
directory = "$test_dir/site"
[[web.vhosts.profiles]]
user = "example"
secret_mode = "dd"
EOF
"$TELEMT_BIN" --data-path "$test_dir" "$test_dir/telemt.toml" > "$test_dir/telemt.log" 2>&1 &
telemt_pid=$!
ready=false
for i in $(seq 1 90); do
    if curl -fsS --max-time 1 -H 'Host: example.test' -H 'X-Forwarded-For: 1.1.1.1' http://127.0.0.1:25080/style.css >/dev/null; then ready=true; break; fi
    kill -0 "$telemt_pid" 2>/dev/null || break
    sleep 1
done
if [ "$ready" != true ]; then tail -30 "$test_dir/telemt.log"; exit 1; fi
INSTALL_DIR="$test_dir"
source "$repo/lib/settings.sh"
source "$repo/lib/web.sh"
WEB_ENABLED=true
PROXY_MODE=web
WEB_LAYOUT=split
WEB_DOMAIN=example.test
WEB_PUBLIC_PORT=25443
WEB_LISTEN_PORT=25080
web_cert_dir() { echo "$test_dir"; }
web_nginx_ipv6_available() { return 1; }
web_csp_policy() { echo "default-src 'self'"; }
generate_nginx() {
    {
        printf 'worker_processes 1;\npid %s/nginx.pid;\nerror_log %s/nginx.log;\nevents { worker_connections 64; }\nhttp {\naccess_log off;\n' "$test_dir" "$test_dir"
        web_nginx_upgrade_map
        web_nginx_http_server "$test_dir" | sed 's/listen 25443 /listen 127.0.0.1:25443 /g'
        echo '}'
    } > "$test_dir/nginx.conf"
    "$NGINX_BIN" -t -p "$test_dir/" -c "$test_dir/nginx.conf"
}
generate_nginx
"$NGINX_BIN" -p "$test_dir/" -c "$test_dir/nginx.conf" -g 'daemon off;' &
nginx_pid=$!
sleep 1
request() { curl -ksS --max-time 10 -H 'Host: example.test' "$@" https://127.0.0.1:25443; }
for path in / /style.css /app.js /missing; do
    code=$(curl -ksS --max-time 10 -H 'Host: example.test' -D "$test_dir/headers" -o "$test_dir/body" -w '%{http_code}' "https://127.0.0.1:25443$path")
    expected=200; [ "$path" != /missing ] || expected=404
    [ "$code" = "$expected" ] || { echo "$path returned $code"; exit 1; }
    [ "$(grep -ic '^Strict-Transport-Security:' "$test_dir/headers")" = 1 ]
    [ "$(grep -ic '^Permissions-Policy:' "$test_dir/headers")" = 1 ]
    grep -q 'max-age=15552000' "$test_dir/headers"
    case "$path" in
        /style.css)
            grep -qi '^content-type: text/css' "$test_dir/headers"
            cmp "$test_dir/body" "$test_dir/site/style.css" ;;
        /app.js)
            grep -Eqi '^content-type: (application|text)/javascript' "$test_dir/headers"
            cmp "$test_dir/body" "$test_dir/site/app.js" ;;
    esac
done
HTTPS_HSTS_ENABLED=false
HTTPS_PERMISSIONS_ENABLED=false
generate_nginx
"$NGINX_BIN" -p "$test_dir/" -c "$test_dir/nginx.conf" -s reload
sleep 1
request -D "$test_dir/headers" -o /dev/null
grep -q 'max-age=0' "$test_dir/headers"
! grep -qi '^Permissions-Policy:' "$test_dir/headers"
curl -fsS http://127.0.0.1:29091/v1/config | jq -e '.data.config.general.log_level == "silent" or .data.general.log_level == "silent"' >/dev/null
echo 'PASS: telemt 3.5.7 static snapshot, nginx headers, errors, disable, config API'
