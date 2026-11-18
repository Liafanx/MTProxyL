#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
[ "${1:-}" = "--inside" ] || exec unshare -n bash "$0" --inside
INSTALL_DIR=$(mktemp -d)
trap 'rm -r -- "$INSTALL_DIR"' EXIT
source lib/utils.sh
source lib/ipblock.sh

log_error() { echo "$*" >&2; }
log_success() { :; }
ipblock_hits_sample() { :; }
ipblock_install_unit() { :; }
save_settings() { echo "$IPBLOCK_ENABLED" > "$INSTALL_DIR/enabled"; }

cat > "$INSTALL_DIR/input" <<'EOF'
192.0.2.0/24 # parent
192.0.2.0/25 # child
2001:db8::/48
2001:db8::/64
EOF
ipblock_import "$INSTALL_DIR/input"
ipblock_enable
[[ $(nft list set inet "$IPBLOCK_TABLE" v4) == *192.0.2.0/24* ]]
[[ $(nft list set inet "$IPBLOCK_TABLE" v6) == *2001:db8::/48* ]]
cmp "$INSTALL_DIR/input" "$IPBLOCK_FILE"
ipblock_apply
before=$(nft list table inet "$IPBLOCK_TABLE")

ipblock_entries() { echo '1::2:3:4:5:6:7:8'; }
if ipblock_apply 2>"$INSTALL_DIR/error"; then exit 1; fi
[ "$(nft list table inet "$IPBLOCK_TABLE")" = "$before" ]
grep -q '^Правила блокировки не изменены: .\+' "$INSTALL_DIR/error"
[ "$(wc -l < "$INSTALL_DIR/error")" -eq 1 ]
IPBLOCK_ENABLED=false
echo false > "$INSTALL_DIR/enabled"
if ipblock_enable 2>/dev/null; then exit 1; fi
[ "$IPBLOCK_ENABLED" = false ]
[ "$(cat "$INSTALL_DIR/enabled")" = false ]
echo 'ipblock intervals: ok'
