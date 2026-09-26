#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
INSTALL_DIR="$test_dir"
source lib/utils.sh
source lib/ipblock.sh

# На минимальном Debian штатный awk может быть mawk, без gawk.
awk() { /usr/bin/mawk "$@"; }
log_error() { printf '%s\n' "$*" >&2; }
log_success() { :; }
ipblock_rules_active() { return 0; }
ipblock_apply() { :; }
TEST_PACKETS=3
TEST_BYTES=240
nft() {
    [ "$1" = list ] && [ "$2" = set ] || return 1
    if [ "$5" = v4 ]; then
        printf 'table inet mtproxyl_block { set v4 { elements = { 188.130.209.0/24 counter packets %s bytes %s, 66.132.186.0/24 counter packets 0 bytes 0 } } }\n' \
            "$TEST_PACKETS" "$TEST_BYTES"
    else
        printf 'table inet mtproxyl_block { set v6 { type ipv6_addr } }\n'
    fi
}

printf '%s\n' \
    '# группа' \
    '188.130.209.0/24 # сканер "А"' \
    '66.132.186.0/24 # проверка' > "$IPBLOCK_FILE"

status=$(ipblock_status_json)
printf '%s\n' "$status" | jq -e '.count == 2 and .hits_total == 3 and
    .comments["188.130.209.0/24"] == "сканер \"А\"" and
    .comments["66.132.186.0/24"] == "проверка"' >/dev/null
[ "$(ipblock_hits_tsv | /usr/bin/mawk -F'\t' '$1 == "188.130.209.0/24" {print $2}')" = 3 ]
TEST_PACKETS=5
TEST_BYTES=400
[ "$(ipblock_status_json | jq -r '.hits_total')" = 5 ]
[ "$(ipblock_status_json | jq -r '.hits_total')" = 5 ]

# Ошибка обработки файла не должна маскироваться успешным удалением.
awk() { return 1; }
if ipblock_del 188.130.209.0/24 >/dev/null 2>&1; then
    echo 'delete succeeded after awk failure' >&2
    exit 1
fi
ipblock_has 188.130.209.0/24
awk() { /usr/bin/mawk "$@"; }
ipblock_del 188.130.209.0/24
if ipblock_has 188.130.209.0/24; then
    echo 'CIDR still blocked after deletion' >&2
    exit 1
fi
grep -q '66.132.186.0/24 # проверка' "$IPBLOCK_FILE"

echo 'ipblock tests: ok'
