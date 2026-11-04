#!/bin/bash
# Запускать в отдельном сетевом пространстве: проверяем настоящие правила nft.
set -euo pipefail
if [ "${1:-}" != --netns ]; then
    exec unshare -n bash "$0" --netns
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source "$repo/lib/colors.sh" || true
for lib in utils settings front nft web; do source "$repo/lib/$lib.sh"; done
_mktemp() { mktemp "${1:-$test_dir}/.test.XXXXXX"; }
log_info() { :; }; log_success() { :; }; log_warn() { :; }
log_error() { echo "$*" >&2; }
systemctl() { printf '%s\n' "$*" >> "$test_dir/systemctl"; }
sleep() { :; }
PROXY_MODE=web WEB_ENABLED=true PROXY_PORT=9443 WEB_PUBLIC_PORT=8443
NFT_SCRIPT_FILE="$test_dir/limiter.sh"
NFT_MODE=classic NFT_ENABLED=false NFT_SERVER_IP=''
ZAPRET2_APPLIED=false ZAPRET2_SERVICE_ENABLED=false
[ "$(nft_default_port)" = 8443 ]
[ "$(zapret2_main_port)" = 8443 ]
apply_nft_rules
rules=$(nft -nn list table inet "$NFT_TABLE")
grep -q 'tcp dport 8443' <<< "$rules"
! grep -q 'tcp dport 9443' <<< "$rules"
NFT_MODE=smart
apply_nft_rules
rules=$(nft -nn list table inet "$NFT_TABLE")
grep -q 'tcp dport 8443' <<< "$rules"
# Существующая несовместимость двух защит остаётся в силе.
ZAPRET2_APPLIED=true
if apply_nft_rules >/dev/null 2>&1; then echo 'Concurrent limiter accepted' >&2; exit 1; fi
nft delete table inet "$NFT_TABLE"
ZAPRET2_BIN=/usr/bin/true
ZAPRET2_ETC_DIR="$test_dir/zapret2"
ZAPRET2_CONF="$ZAPRET2_ETC_DIR/mtproto.conf"
NFT_ENABLED=false
zapret2_apply_nft() { printf '%s\n' "$(zapret2_main_port)" > "$test_dir/zapret-port"; }
zapret2_start
zapret2_start_existing
grep -qx 8443 "$test_dir/zapret-port"
grep -q -- '--filter-tcp=8443\|--filter-tcp 8443' "$ZAPRET2_CONF"
grep -qx "restart $ZAPRET2_SERVICE" "$test_dir/systemctl"
ZAPRET2_PORT=10443
[ "$(zapret2_main_port)" = 10443 ]
ZAPRET2_PORT=''
WEB_FRONTEND=haproxy
[ "$(nft_default_port)" = 443 ]
WEB_FRONTEND=nginx WEB_LAYOUT=split WEB_CARRIER=https
web_zapret2_hurts
PROXY_MODE=combined
[ "$(nft_default_port)" = 9443 ]
! web_zapret2_hurts
# Возврат в combined не заменяет ручной лимитер ранее снятым Zapret2.
PROXY_MODE=web
ZAPRET2_APPLIED=false ZAPRET2_SERVICE_ENABLED=false
apply_nft_rules
PROXY_MODE=combined
WEB_ONLY_PREV_NFT=false WEB_ONLY_PREV_ZAPRET2=true
load_nft_settings() { :; }; save_settings() { :; }
install_nft_service() { :; }
_web_resume_mtproto_fixes
rules=$(nft -nn list table inet "$NFT_TABLE")
grep -q 'tcp dport 9443' <<< "$rules"
[ "$WEB_ONLY_PREV_NFT:$WEB_ONLY_PREV_ZAPRET2" = false:false ]
# Обратный выбор: ручной Zapret2 возвращается с конфигом порта MTProto.
nft delete table inet "$NFT_TABLE"
ZAPRET2_APPLIED=true
WEB_ONLY_PREV_NFT=true WEB_ONLY_PREV_ZAPRET2=false
_web_resume_mtproto_fixes
grep -qx 9443 "$test_dir/zapret-port"
grep -q -- '--filter-tcp=9443\|--filter-tcp 9443' "$ZAPRET2_CONF"
echo 'WEB-only manual limiter/Zapret2: OK (nft in netns, service mocked)'
