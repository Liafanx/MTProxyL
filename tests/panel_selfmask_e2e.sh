#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
panel_repo="$repo/mtproxyl-panel"
nginx_bin="${NGINX_TEST_BIN:-/opt/mtproxyl-nginx/sbin/nginx}"

for dependency in go curl jq openssl python3; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "SKIP: $dependency is unavailable"
        exit 0
    }
done
[ -x "$nginx_bin" ] || { echo "SKIP: MTProxyL nginx is unavailable"; exit 0; }
[ -f "$panel_repo/dist/index.html" ] || { echo "SKIP: panel frontend dist is unavailable"; exit 0; }

test_dir=$(mktemp -d /tmp/mtproxyl-panel-e2e.XXXXXX)
panel_pid=""; nginx_pid=""
cleanup() {
    [ -z "$nginx_pid" ] || kill "$nginx_pid" 2>/dev/null || true
    [ -z "$panel_pid" ] || kill "$panel_pid" 2>/dev/null || true
    wait "$nginx_pid" 2>/dev/null || true
    wait "$panel_pid" 2>/dev/null || true
    rm -rf "$test_dir"
}
trap cleanup EXIT

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

panel_port=$(free_port)
front_port=$(free_port)
[ "$front_port" != "$panel_port" ] || front_port=$(free_port)
base_path="${PANEL_E2E_PATH:-/0123456789abcdef0123456789abcdef}"
case "$base_path" in /*) ;; *) base_path="/$base_path" ;; esac
domain="mask.example.com"
backend_scheme="http"
backend_curl=()
panel_tls_block=""
if [ "${PANEL_E2E_BACKEND_TLS:-false}" = "true" ]; then
    backend_scheme="https"
    backend_curl=(--insecure)
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=panel-backend.local' \
        -keyout "$test_dir/panel-key.pem" -out "$test_dir/panel-cert.pem" >/dev/null 2>&1
    panel_tls_block="
[tls]
cert_file = \"$test_dir/panel-cert.pem\"
key_file = \"$test_dir/panel-key.pem\""
fi

(cd "$panel_repo" && go build -ldflags='-s -w -X main.version=e2e' -o "$test_dir/panel" .)
password_hash=$(printf 'panel-test-password\n' | "$test_dir/panel" hash-password)
mkdir -p "$test_dir/panel-config" "$test_dir/data"
history_limit_file="$test_dir/history-limit"
printf '1000\n' > "$history_limit_file"
cat > "$test_dir/mtproxyl.sh" <<EOF
#!/bin/sh
if [ "\$1" = availability ] && [ "\$2" = history ]; then
    printf '{"limit":%s,"points":[{"checked_at":"2026-09-12T00:00:00Z","target":"proxy.example.com:443","level":"yellow","percentage":75,"success_probes":18,"total_probes":24,"measurement_id":"m1","error":""}]}\n' "\$(cat "$history_limit_file")"
    exit 0
fi
if [ "\$1" = settings ] && [ "\$2" = set ] && [ "\$3" = AVAILABILITY_HISTORY_LIMIT ]; then
    printf '%s\n' "\$4" > "$history_limit_file"
    exit 0
fi
exit 1
EOF
chmod 700 "$test_dir/mtproxyl.sh"
cat > "$test_dir/panel-config/config.toml" <<EOF
listen = "127.0.0.1:${panel_port}"
base_path = "${base_path}"
data_dir = "${test_dir}/data"

[telemt]
url = "http://127.0.0.1:1"

[auth]
username = "admin"
password_hash = "${password_hash}"
jwt_secret = "0123456789abcdef0123456789abcdef"
session_ttl = "1h"

[mtproxyl]
enabled = true
script_path = "$test_dir/mtproxyl.sh"
install_dir = "$test_dir/state"
use_sudo = false
${panel_tls_block}
EOF

"$test_dir/panel" --config "$test_dir/panel-config/config.toml" >"$test_dir/panel.log" 2>&1 &
panel_pid=$!
for _ in {1..50}; do
    curl --noproxy '*' "${backend_curl[@]}" -fsS "${backend_scheme}://127.0.0.1:${panel_port}${base_path}/api/branding" >/dev/null 2>&1 && break
    sleep 0.1
done
kill -0 "$panel_pid" 2>/dev/null || { cat "$test_dir/panel.log" >&2; exit 1; }

# Получаем ровно тот proxy location, который генерирует Selfmask.
INSTALL_DIR="$test_dir/state"
CONFIG_DIR="$INSTALL_DIR/mtproxy"
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
PANEL_CONFIG_DIR="$test_dir/panel-config"
PANEL_BINARY="$test_dir/panel"
PANEL_SELFMASK_ENABLED=true
PANEL_SELFMASK_PATH="$base_path"
NGINX_CUSTOM_ENABLED=false
proxy_block=$(_selfmask_panel_proxy_block)
[[ "$proxy_block" == *"proxy_pass ${backend_scheme}://127.0.0.1:${panel_port};"* ]]

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}" -keyout "$test_dir/key.pem" \
    -out "$test_dir/cert.pem" >/dev/null 2>&1
{
    printf 'pid %s;\n' "$test_dir/nginx.pid"
    printf 'error_log %s;\n' "$test_dir/nginx-error.log"
    printf 'events { worker_connections 32; }\n'
    printf 'http { access_log off;\n'
    if [ "${PANEL_E2E_FRONTEND:-selfmask}" = web ]; then
        WEB_ENABLED=true
        PROXY_MODE=web
        WEB_DOMAIN="$domain"
        WEB_PUBLIC_PORT="$front_port"
        WEB_LISTEN_ADDR=127.0.0.1
        WEB_LISTEN_PORT=$(free_port)
        WEB_FRONTEND=nginx
        web_cert_dir() { printf '%s\n' "$test_dir"; }
        cp "$test_dir/cert.pem" "$test_dir/fullchain.pem"
        cp "$test_dir/key.pem" "$test_dir/privkey.pem"
        web_nginx_upgrade_map
        web_nginx_http_server "$test_dir"
    else
        printf 'server { listen 127.0.0.1:%s ssl; server_name %s;\n' "$front_port" "$domain"
        printf 'ssl_certificate %s; ssl_certificate_key %s;\n' "$test_dir/cert.pem" "$test_dir/key.pem"
        printf '%s\n' "$proxy_block"
        printf 'location / { return 404; }\n}\n'
    fi
    printf '}\n'
} > "$test_dir/nginx.conf"
"$nginx_bin" -t -p "$test_dir/" -c "$test_dir/nginx.conf" >/dev/null 2>&1
"$nginx_bin" -p "$test_dir/" -c "$test_dir/nginx.conf" -g 'daemon off;' >"$test_dir/nginx.log" 2>&1 &
nginx_pid=$!

base_url="https://${domain}:${front_port}${base_path}"
curl_common=(--noproxy '*' --insecure --silent --show-error --resolve "${domain}:${front_port}:127.0.0.1")
for _ in {1..50}; do
    curl "${curl_common[@]}" --fail "${base_url}/" -o "$test_dir/index.html" 2>/dev/null && break
    sleep 0.1
done
kill -0 "$nginx_pid" 2>/dev/null || { cat "$test_dir/nginx.log" >&2; exit 1; }

grep -Fq "window.__BASE_PATH__=\"${base_path}\"" "$test_dir/index.html"
grep -Fq "<base href=\"${base_path}/\">" "$test_dir/index.html"

# Запрос без завершающего слеша должен остаться на внешнем origin. Nginx
# Selfmask/HAProxy слушает внутри 8444/15444; абсолютный редирект раскрывал этот
# порт и отправлял браузер туда, где снаружи ничего не слушает.
redirect_code=$(curl "${curl_common[@]}" --dump-header "$test_dir/redirect.headers" \
    --output /dev/null --write-out '%{http_code}' "$base_url")
[ "$redirect_code" = "308" ]
redirect_location=$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$test_dir/redirect.headers" | tr -d '\r' | head -1)
[ "$redirect_location" = "${base_path}/" ]

wrong_code=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' "https://${domain}:${front_port}/")
# Корень не должен открыть панель. В WEB-тесте ответ зависит от того, успел ли
# nginx соединиться с заведомо отсутствующим тестовым backend.
case "$wrong_code" in
    404|502) ;;
    *) exit 1 ;;
esac
asset=$(find "$panel_repo/dist/assets" -maxdepth 1 -type f | head -1)
curl "${curl_common[@]}" --fail --output /dev/null "${base_url}/assets/$(basename "$asset")"

# Случайный путь скрывает страницу, но не заменяет логин и пароль: никакой
# защищённый API не должен отвечать до создания сессии.
unauth_me=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' "${base_url}/api/auth/me")
unauth_data=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' "${base_url}/api/users/defaults")
unauth_history=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' "${base_url}/api/availability/history")
[ "$unauth_me" = "401" ]
[ "$unauth_data" = "401" ]
[ "$unauth_history" = "401" ]

cookie_jar="$test_dir/cookies.txt"
curl "${curl_common[@]}" --fail --dump-header "$test_dir/login.headers" \
    --cookie-jar "$cookie_jar" -H 'Content-Type: application/json' \
    --data '{"username":"admin","password":"panel-test-password"}' \
    "${base_url}/api/auth/login" | jq -e '.ok == true' >/dev/null
chmod 600 "$cookie_jar"
python3 - "$test_dir/background.png" <<'PY'
import sys
with open(sys.argv[1], 'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n' + bytes(2621440))
PY
curl "${curl_common[@]}" --fail --cookie "$cookie_jar" -H 'Content-Type: image/png' \
    -X PUT --data-binary "@$test_dir/background.png" "${base_url}/api/panel/settings/background" \
    | jq -e '.ok == true and .data.has_background == true' >/dev/null
png_icon_code=$(curl "${curl_common[@]}" --cookie "$cookie_jar" -H 'Content-Type: image/png' \
    -X PUT --data-binary "@$test_dir/background.png" --output /dev/null --write-out '%{http_code}' \
    "${base_url}/api/panel/settings/icon")
[ "$png_icon_code" = "400" ]
python3 - "$test_dir/panel.ico" <<'PY'
import sys
with open(sys.argv[1], 'wb') as f:
    f.write(b'\x00\x00\x01\x00' + bytes(32))
PY
curl "${curl_common[@]}" --fail --cookie "$cookie_jar" -H 'Content-Type: image/x-icon' \
    -X PUT --data-binary "@$test_dir/panel.ico" "${base_url}/api/panel/settings/icon" \
    | jq -e '.ok == true and .data.has_icon == true' >/dev/null
curl "${curl_common[@]}" --fail "${base_url}/api/branding/icon" -o "$test_dir/downloaded-icon"
cmp "$test_dir/panel.ico" "$test_dir/downloaded-icon"
curl "${curl_common[@]}" --fail --cookie "$cookie_jar" -X DELETE "${base_url}/api/panel/settings/icon" \
    | jq -e '.ok == true and .data.has_icon == false' >/dev/null
grep -qi "Set-Cookie: session=.*Path=${base_path}/.*HttpOnly.*Secure.*SameSite=Strict" "$test_dir/login.headers"
grep -qi '^Strict-Transport-Security:' "$test_dir/login.headers"
curl "${curl_common[@]}" --fail --cookie "$cookie_jar" "${base_url}/api/auth/me" \
    | jq -e '.ok == true and .data.username == "admin"' >/dev/null
curl "${curl_common[@]}" --fail --cookie "$cookie_jar" "${base_url}/api/availability/history" \
    | jq -e '.ok == true and .data.limit == 1000 and .data.points[0].success_probes == 18 and .data.points[0].total_probes == 24' >/dev/null
curl "${curl_common[@]}" --fail --cookie "$cookie_jar" -H 'Content-Type: application/json' \
    -X PUT --data '{"limit":250}' "${base_url}/api/availability/history" \
    | jq -e '.ok == true and .data.limit == 250' >/dev/null
invalid_limit=$(curl "${curl_common[@]}" --cookie "$cookie_jar" -H 'Content-Type: application/json' \
    -X PUT --data '{"limit":0}' --output /dev/null --write-out '%{http_code}' "${base_url}/api/availability/history")
[ "$invalid_limit" = "400" ]

# Проверяем, что Upgrade/Connection проходят через тот же location. Сырой
# клиент читает только HTTP-заголовок и не зависает на открытом WebSocket.
python3 - "$front_port" "$domain" "$base_path" "$cookie_jar" <<'PY'
import socket, ssl, sys

port, domain, base_path, cookie_path = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
session = ""
with open(cookie_path, encoding="utf-8") as cookies:
    for line in cookies:
        if line.startswith("#") and not line.startswith("#HttpOnly_"):
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) == 7 and fields[5] == "session":
            session = fields[6]
            break
assert session, "session cookie missing"

context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
with socket.create_connection(("127.0.0.1", port), timeout=3) as raw:
    with context.wrap_socket(raw, server_hostname=domain) as conn:
        request = (
            f"GET {base_path}/api/ws/logs HTTP/1.1\r\n"
            f"Host: {domain}\r\n"
            "Connection: Upgrade\r\n"
            "Upgrade: websocket\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            f"Cookie: session={session}\r\n\r\n"
        )
        conn.sendall(request.encode("ascii"))
        response = conn.recv(4096)
assert b" 101 " in response.split(b"\r\n", 1)[0], response[:500]
PY

echo "panel Selfmask end-to-end test (${backend_scheme} backend): OK"
