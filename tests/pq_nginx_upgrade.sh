#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
[ "${1:-}" = "--inside" ] || exec unshare -m --propagation private bash "$0" --inside
work=$(mktemp -d)
pid=""
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -r -- "$work"' EXIT
mkdir "$work/var-log" "$work/var-lib"
mount --bind "$work/var-log" /var/log
mount --bind "$work/var-lib" /var/lib
INSTALL_DIR="$work/mtproxyl"
source lib/utils.sh
source lib/selfmask.sh
SELFMASK_PQ_PREFIX="$work/installed"
GITHUB_REPO=Liafanx/MTProxyL
log_info() { :; }
log_success() { :; }
log_error() { echo "$*" >&2; }
_front_arch() { echo amd64; }
_selfmask_pq_conf() { echo "$SELFMASK_PQ_PREFIX/conf/nginx.conf"; }

dist="$work/dist"
root="$dist/opt/mtproxyl-nginx"
mkdir -p "$root"/{bin,sbin,conf,html}
cat > "$root/sbin/nginx" <<EOF
#!/bin/bash
case "\$1" in
    -V) printf '%s\\n' 'nginx version: nginx/${SELFMASK_PQ_NGINX_VERSION}' 'built with OpenSSL ${SELFMASK_PQ_OPENSSL_VERSION} test' >&2 ;;
    -v) echo 'nginx version: nginx/${SELFMASK_PQ_NGINX_VERSION}' >&2 ;;
    -t) [ "\${INVALID_CONFIG:-}" != 1 ] && grep -qx 'live config' "\$3" ;;
    *) exit 1 ;;
esac
EOF
printf '#!/bin/bash\necho "OpenSSL %s fixture"\n' "$SELFMASK_PQ_OPENSSL_VERSION" > "$root/bin/openssl"
chmod +x "$root"/{bin/openssl,sbin/nginx}
echo stock > "$root/conf/nginx.conf"
echo mime > "$root/conf/mime.types"
echo welcome > "$root/html/index.html"
tar czf "$work/nginx.tar.gz" -C "$dist" opt
sha256sum "$work/nginx.tar.gz" > "$work/checksum"

curl() {
    echo requested >> "$work/requests"
    case " $* " in
        *'.sha256 '*) cp "$work/checksum" "${*: -1}" ;;
        *) cp "$work/nginx.tar.gz" "${*: -1}" ;;
    esac
}
systemctl() {
    case "$1" in
        show) echo "${pid:-0}" ;;
        restart)
            echo restart >> "$work/restarts"
            if [ "${RESTART_FAIL:-}" = 1 ]; then
                cmp -s "$SELFMASK_PQ_PREFIX/sbin/nginx" "$work/previous-nginx"
            fi
            ;;
        *) return 1 ;;
    esac
}

_selfmask_update_bundled_pq
[ ! -e "$work/requests" ]
mkdir -p "$SELFMASK_PQ_PREFIX"/{sbin,bin,conf}
cp "$(command -v sleep)" "$SELFMASK_PQ_PREFIX/sbin/nginx"
cp "$SELFMASK_PQ_PREFIX/sbin/nginx" "$work/previous-nginx"
echo 'live config' > "$SELFMASK_PQ_PREFIX/conf/nginx.conf"
echo certificate > "$SELFMASK_PQ_PREFIX/conf/fixture.pem"
start_fixture() {
    local i
    "$SELFMASK_PQ_PREFIX/sbin/nginx" 60 &
    pid=$!
    for ((i=0; i<100; i++)); do
        [ "/proc/$pid/exe" -ef "$SELFMASK_PQ_PREFIX/sbin/nginx" ] && return 0
        sleep 0.01
    done
    return 1
}
start_fixture

cp "$work/checksum" "$work/checksum.ok"
echo invalid > "$work/checksum"
if _selfmask_replace_pq_nginx 2>/dev/null; then exit 1; fi
cmp "$SELFMASK_PQ_PREFIX/sbin/nginx" "$work/previous-nginx"
cp "$work/checksum.ok" "$work/checksum"
if INVALID_CONFIG=1 _selfmask_replace_pq_nginx 2>/dev/null; then exit 1; fi
[ ! -e "$work/restarts" ]
if RESTART_FAIL=1 _selfmask_replace_pq_nginx 2>/dev/null; then exit 1; fi
cmp "$SELFMASK_PQ_PREFIX/sbin/nginx" "$work/previous-nginx"
[ ! -e "$SELFMASK_PQ_PREFIX/bin/openssl" ]
[ "$(wc -l < "$work/restarts")" -eq 2 ]
kill "$pid"
wait "$pid" 2>/dev/null || true
start_fixture
_selfmask_update_bundled_pq
cmp "$SELFMASK_PQ_PREFIX/sbin/nginx" "$root/sbin/nginx"
grep -qx 'live config' "$SELFMASK_PQ_PREFIX/conf/nginx.conf"
grep -qx certificate "$SELFMASK_PQ_PREFIX/conf/fixture.pem"
[ "$(wc -l < "$work/restarts")" -eq 3 ]
requests=$(wc -l < "$work/requests")
_selfmask_update_bundled_pq
[ "$(wc -l < "$work/requests")" -eq "$requests" ]
echo 'pq nginx upgrade: ok'
