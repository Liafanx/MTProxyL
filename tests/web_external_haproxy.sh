#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/mtproxyl-web-external.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

INSTALL_DIR="$test_dir"
CONFIG_DIR="$test_dir/mtproxy"
SETTINGS_FILE="$test_dir/settings.conf"
EXPERT_OVERRIDES_FILE="$test_dir/expert.conf"
VERSION=dev
mkdir -p "$CONFIG_DIR"

# shellcheck source=/dev/null
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/web.sh"
source "$repo/lib/expert_catalog.sh"
source "$repo/lib/expert_mode.sh"

_mktemp() { mktemp "$1/.test.XXXXXX"; }

WEB_ENABLED=true
PROXY_MODE=combined
WEB_LAYOUT=shared
WEB_FRONTEND=haproxy
WEB_DOMAIN=web.example.test
WEB_LISTEN_ADDR=10.20.30.40
WEB_LISTEN_PORT=25080
WEB_MTPROXY_PORT=25443
WEB_TLS_PORT=25444
WEB_TRUSTED_PROXY_CIDRS='10.20.30.5/32,10.20.31.0/24'
PROXY_PROTOCOL_TRUSTED_CIDRS=''

! web_dns_must_point_to_this_server
WEB_LISTEN_ADDR=127.0.0.1
web_dns_must_point_to_this_server
WEB_LISTEN_ADDR=10.20.30.40

(
    web_domain_ips() { echo 203.0.113.25; }
    web_server_ip() { echo 198.51.100.10; }
    web_public_addr() { echo 203.0.113.25:443; }
    web_engine_supports() { return 0; }
    web_profile_count() { echo 1; }
    get_expert_override_value() { return 0; }
    web_busy_ports() { return 0; }
    SELFMASK_ENABLED=false
    WEB_DECOY_MODE=empty
    PROXY_DOMAIN=mask.example.test
    PROXY_PORT=443
    problems=$(web_preflight_problems)
    [ -z "$problems" ] || { echo "unexpected remote HAProxy preflight: $problems" >&2; exit 1; }
    WEB_LISTEN_ADDR=127.0.0.1
    problems=$(web_preflight_problems)
    grep -Fq 'публичная A-запись' <<< "$problems"
)

set +u
save_settings
set -u
grep -Fq "WEB_LISTEN_ADDR='10.20.30.40'" "$SETTINGS_FILE"
grep -Fq "WEB_TRUSTED_PROXY_CIDRS='10.20.30.5/32,10.20.31.0/24'" "$SETTINGS_FILE"
web_settable_json | jq -e '
    any(.[]; .key == "WEB_LISTEN_ADDR" and .value == "10.20.30.40") and
    any(.[]; .key == "WEB_TRUSTED_PROXY_CIDRS" and .value == "10.20.30.5/32,10.20.31.0/24")
' >/dev/null

listeners=$(web_listeners_toml)
[ "$(grep -c '^ip = "10.20.30.40"$' <<< "$listeners")" -eq 2 ]
grep -Fq 'web_trusted_proxy_cidrs = ["10.20.30.5/32", "10.20.31.0/24"]' <<< "$listeners"
grep -Fq 'proxy_protocol_trusted_cidrs = ["10.20.30.5/32", "10.20.31.0/24"]' \
    <<< "$(web_proxy_protocol_trusted_toml)"

haproxy=$(web_haproxy_config)
grep -Fq 'server mtproxyl_mtproto_1 10.20.30.40:25443 send-proxy' <<< "$haproxy"
grep -Fq 'server mtproxyl_web_1 10.20.30.40:25080 check' <<< "$haproxy"

_validate_web_listen_addr 0.0.0.0
_validate_web_listen_addr 10.20.30.40
! _validate_web_listen_addr example.com >/dev/null 2>&1
_validate_web_trusted_proxy_cidrs '127.0.0.1/32,10.0.0.0/8'
! _validate_web_trusted_proxy_cidrs '' >/dev/null 2>&1
! _validate_web_trusted_proxy_cidrs '0.0.0.0/0' >/dev/null 2>&1
! _validate_web_trusted_proxy_cidrs '::/0' >/dev/null 2>&1

_expert_find server.listeners web_trusted_proxy_cidrs >/dev/null
_expert_find server proxy_protocol_trusted_cidrs >/dev/null

cat > "$test_dir/config.toml" <<'EOF'
[server]
proxy_protocol = false

[[server.listeners]]
ip = "127.0.0.1"
port = 25443
transport = "mtproxy"
proxy_protocol = true

[[server.listeners]]
ip = "127.0.0.1"
port = 25080
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[server.api]
enabled = true
EOF
printf 'server.listeners|web_trusted_proxy_cidrs|10.20.30.5/32,10.20.31.0/24\n' \
    > "$EXPERT_OVERRIDES_FILE"
_apply_expert_overrides "$test_dir/config.toml"

# WEB-only key must not leak into the preceding MTProxy listener.
awk '
    /^\[\[server.listeners\]\]$/ { listener++; next }
    listener == 1 && /^web_trusted_proxy_cidrs[[:space:]]*=/ { exit 1 }
    listener == 2 && $0 == "web_trusted_proxy_cidrs = [\"10.20.30.5/32\", \"10.20.31.0/24\"]" { found=1 }
    END { exit !found }
' "$test_dir/config.toml"

# Сохранённый override ждёт включения WEB и не создаёт неполный listener.
printf '[server]\nport = 443\n' > "$test_dir/no-web.toml"
_apply_expert_overrides "$test_dir/no-web.toml"
! grep -Fq '[[server.listeners]]' "$test_dir/no-web.toml"

echo "web external HAProxy tests: OK"
