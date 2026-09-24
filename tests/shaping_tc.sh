#!/bin/bash
# Изолированная проверка tc/HTB: не меняет qdisc рабочего интерфейса.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ip >/dev/null && command -v tc >/dev/null && command -v jq >/dev/null || {
    echo 'skip: ip/tc/jq unavailable'; exit 0;
}
namespace="mtproxyl-shaping-test-$$"
test_dir=$(mktemp -d)
cleanup() {
    ip netns del "$namespace" >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
if ! ip netns add "$namespace" 2>/dev/null; then echo 'skip: no CAP_NET_ADMIN'; exit 0; fi
ip -n "$namespace" link add test0 type dummy
ip -n "$namespace" link set test0 up
ip netns exec "$namespace" tc qdisc replace dev test0 root fq

INSTALL_DIR="$test_dir"
PROXY_PORT=443
source lib/shaping.sh
tc() { ip netns exec "$namespace" /usr/sbin/tc "$@"; }
shaping_interface() { echo test0; }
web_is_enabled() { return 1; }
cfg=$(shaping_default_config | jq '.enabled=true | .ip_exempt=["203.0.113.0/24"]')
shaping_tc_apply "$cfg"
shaping_tc_owned test0
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:20")' >/dev/null
tc -j filter show dev test0 parent a11: | jq -e 'any(.[]; .options.classid? == "a11:10")' >/dev/null
shaping_tc_disable
[ "$(shaping_root_kind test0)" = fq ]

# Полный цикл включения/выключения: без реального telemt и systemd.
SHAPING_BOOT_UNIT="$test_dir/boot.service"
SHAPING_TICK_UNIT="$test_dir/tick.service"
SHAPING_TIMER_UNIT="$test_dir/tick.timer"
_superexpert_active() { return 1; }
shaping_reload_telemt() { :; }
systemctl() { :; }
log_success() { :; }
log_error() { echo "$*" >&2; }
log_warn() { echo "$*" >&2; }
printf '%s\n' "$cfg" | shaping_apply
shaping_tc_owned test0
printf '%s\n' "$cfg" | jq '.enabled=false' | shaping_apply
[ "$(shaping_root_kind test0)" = fq ]
[ "$(jq -r '.enabled' "$SHAPING_FILE")" = false ]

# Чужой нестандартный qdisc не заменяем.
tc qdisc replace dev test0 root tbf rate 10mbit burst 16kbit latency 50ms
if shaping_tc_apply "$cfg" >/dev/null 2>&1; then echo 'foreign qdisc overwritten' >&2; exit 1; fi
[ "$(shaping_root_kind test0)" = tbf ]
echo 'shaping tc tests: ok'
