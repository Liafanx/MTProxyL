#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
INSTALL_DIR="$tmp"
source lib/utils.sh
source lib/nft.sh

ZAPRET2_DIR="$tmp/installed"
ZAPRET2_BIN="$ZAPRET2_DIR/bin/nfqws2"
ZAPRET2_CACHE_DIR="$ZAPRET2_DIR/cache"
ZAPRET2_LUA_DIR="$ZAPRET2_DIR/lua"
ZAPRET2_LUA="$ZAPRET2_LUA_DIR/mtproto.lua"
ZAPRET2_ETC_DIR="$tmp/etc"
ZAPRET2_CONF="$ZAPRET2_ETC_DIR/mtproto.conf"
archive="$tmp/current.tar.gz"
restarts="$tmp/restarts"
downloads="$tmp/downloads"
: > "$restarts"
: > "$downloads"

ensure_nftables_installed() { :; }
zapret2_detect_arch() { echo amd64; }
log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { :; }
sleep() { :; }
curl() {
    echo download >> "$downloads"
    cp "$download_source" "$5"
}
systemctl() {
    case "$1" in
        is-active) [ "$active" = true ] ;;
        restart)
            "$ZAPRET2_BIN" --version >> "$restarts"
            [ "$fail_new" != true ] || ! grep -q "version $ZAPRET2_RELEASE " < <("$ZAPRET2_BIN" --version)
            ;;
        *) return 1 ;;
    esac
}

payload="$tmp/content/zapret2-$ZAPRET2_RELEASE"
mkdir -p "$payload/binaries/linux-x86_64" "$payload/lua"
for name in lib antidpi auto; do echo new > "$payload/lua/zapret-$name.lua"; done
for name in mdig ip2net; do echo new > "$payload/binaries/linux-x86_64/$name"; done
cat > "$payload/binaries/linux-x86_64/nfqws2" <<EOF
#!/bin/bash
if [[ \$1 == --version ]]; then
    echo 'github version $ZAPRET2_RELEASE (test)'
    exit 0
fi
file=\${1#@}
grep -qx -- --dry-run "\$file" && ! grep -q -- '--debug\|--unsupported' "\$file" || exit 1
path=\$(sed -n 's|^--lua-init=@\(.*zapret-lib.lua\)$|\1|p' "\$file")
grep -qx new "\$path"
EOF
tar -czf "$archive" -C "$tmp/content" "zapret2-$ZAPRET2_RELEASE"
ZAPRET2_RELEASE_SHA256=$(sha256sum "$archive" | cut -d ' ' -f 1)
printf bad > "$tmp/bad.tar.gz"
download_source="$archive"
active=false fail_new=false ZAPRET2_APPLIED=false
zapret2_refresh_if_needed
[[ ! -s "$downloads" ]]

zapret2_download_bundle
[[ -x "$ZAPRET2_BIN" && ! -s "$restarts" ]]
grep -q "zapret2 $ZAPRET2_RELEASE " "$ZAPRET2_DIR/version"
[[ "$(wc -l < "$downloads")" -eq 1 ]]

old_bundle() {
    printf '#!/bin/sh\necho "github version v1.0.5.2 (test)"\n' > "$ZAPRET2_BIN"
    echo 'zapret2 v1.0.5.2' > "$ZAPRET2_DIR/version"
    echo old > "$ZAPRET2_LUA_DIR/zapret-lib.lua"
}
old_bundle
export ZAPRET2_APPLIED=true
printf '%s\n' "--lua-init=@$ZAPRET2_LUA_DIR/zapret-lib.lua" --debug=@example > "$ZAPRET2_CONF"
cp "$ZAPRET2_CONF" "${ZAPRET2_CONF%.conf}-1.conf"
echo custom > "$ZAPRET2_LUA"
before_custom=$(sha256sum "$ZAPRET2_LUA" "$ZAPRET2_CONF" "${ZAPRET2_CONF%.conf}-1.conf")

rm -- "$(zapret2_bundle_cache_file)"
active=true download_source="$tmp/bad.tar.gz"
if zapret2_download_bundle "" upgrade; then exit 1; fi
[[ ! -s "$restarts" ]]
grep -qx old "$ZAPRET2_LUA_DIR/zapret-lib.lua"

download_source="$archive"
echo --unsupported >> "${ZAPRET2_CONF%.conf}-1.conf"
if zapret2_download_bundle "" upgrade; then exit 1; fi
[[ ! -s "$restarts" ]]
grep -q 'v1.0.5.2' < <("$ZAPRET2_BIN" --version)
cp "$ZAPRET2_CONF" "${ZAPRET2_CONF%.conf}-1.conf"

fail_new=true
if zapret2_download_bundle "" upgrade; then exit 1; fi
[[ "$(wc -l < "$restarts")" -eq 2 ]]
grep -q 'v1.0.5.2' < <(tail -1 "$restarts")
grep -qx old "$ZAPRET2_LUA_DIR/zapret-lib.lua"
grep -qx 'zapret2 v1.0.5.2' "$ZAPRET2_DIR/version"

fail_new=false
zapret2_download_bundle "" upgrade
zapret2_download_bundle "" upgrade
[[ "$(wc -l < "$restarts")" -eq 3 ]]
grep -q "$ZAPRET2_RELEASE" < <(tail -1 "$restarts")

old_bundle
active=false
zapret2_refresh_if_needed
[[ "$(wc -l < "$restarts")" -eq 3 && "$(wc -l < "$downloads")" -eq 3 ]]
[[ "$(sha256sum "$ZAPRET2_LUA" "$ZAPRET2_CONF" "${ZAPRET2_CONF%.conf}-1.conf")" = "$before_custom" ]]
echo OK
