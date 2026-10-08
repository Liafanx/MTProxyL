#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source "$repo/lib/utils.sh"
source "$repo/lib/settings.sh"
source "$repo/lib/selfmask.sh"

SELFMASK_LOG_DIR="$test_dir/log"
SELFMASK_LOGROTATE="$test_dir/logrotate"
ZAPRET2_DEBUG_LOG="$test_dir/nfqws2.log"
mkdir -p "$SELFMASK_LOG_DIR"
_selfmask_generated_pq_conf() { echo "$test_dir/nginx.conf"; }
_selfmask_nginx_bin_for_conf() { echo true; }
systemctl() { :; }
id() { echo 0; }

# Access log is off unless asked for.
[ "$(_selfmask_nginx_access_log)" = "    access_log off;" ]
NGINX_ACCESS_LOG=true
[[ "$(_selfmask_nginx_access_log)" == *"$SELFMASK_LOG_DIR/access.log combined buffer="* ]]
NGINX_ACCESS_LOG=false

# Old generated config gets the line once, right after the http-level server_tokens.
printf 'http {\n    server_tokens off;\n    server {\n        server_tokens off;\n    }\n}\n' > "$test_dir/nginx.conf"
truncate -s 120M "$SELFMASK_LOG_DIR/access.log"
printf 'small\n' > "$SELFMASK_LOG_DIR/error.log"
_selfmask_ensure_log_limits
[ "$(sed -n 3p "$test_dir/nginx.conf")" = "    access_log off;" ]
[ "$(grep -c access_log "$test_dir/nginx.conf")" -eq 1 ]
_selfmask_ensure_log_limits
[ "$(grep -c access_log "$test_dir/nginx.conf")" -eq 1 ]
[ "$(stat -c %s "$SELFMASK_LOG_DIR/access.log")" -eq 10485760 ]
[ "$(cat "$SELFMASK_LOG_DIR/error.log")" = small ]
grep -q "^$SELFMASK_LOG_DIR/\*.log {" "$SELFMASK_LOGROTATE"
grep -q 'maxsize 20M' "$SELFMASK_LOGROTATE"
grep -q 'kill -USR1 "$(cat /run/mtproxyl-nginx.pid)"' "$SELFMASK_LOGROTATE"

# nginx rejects the patched config: the original stays, no retries.
printf 'http {\n    server_tokens off;\n}\n' > "$test_dir/nginx.conf"
_selfmask_nginx_bin_for_conf() { echo false; }
_selfmask_patch_access_log
if grep -q access_log "$test_dir/nginx.conf"; then exit 1; fi
[ -e "$test_dir/nginx.conf.log-patch-failed" ]

# Own nginx config is never touched.
rm -f "$test_dir/nginx.conf.log-patch-failed"
_selfmask_nginx_bin_for_conf() { echo true; }
NGINX_CUSTOM_ENABLED=true
_selfmask_patch_access_log
if grep -q access_log "$test_dir/nginx.conf"; then exit 1; fi

echo 'log limits: ok'
